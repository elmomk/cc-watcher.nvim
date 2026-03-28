-- sidebar.lua — Sidebar showing files Claude Code has touched
-- Directory grouping, +N/-M stats, file icons, g? help, timer-safe.

local M = {}

local watcher = require("cc-watcher.watcher")
local session = require("cc-watcher.session")
local highlights = require("cc-watcher.highlights")
local diff = require("cc-watcher.diff")
local util = require("cc-watcher.util")

local sidebar_buf = nil
local sidebar_win = nil
local HEADER_LINES = 3 -- title, status, separator

local displayed_files = {}
local line_to_file = {} -- line number -> file entry, rebuilt each render
local latest_changed_file = nil -- abs path of most recently changed file

-- History state
local history_commits = {} -- { { hash, subject, files = { rel, ... } }, ... }
local history_idx = 0 -- 0 = current/uncommitted, 1+ = index into history_commits
local history_loaded = false
local ns = vim.api.nvim_create_namespace("claude_sidebar")
local augroup = vim.api.nvim_create_augroup("ClaudeSidebar", { clear = true })

-- Debounce intervals (ms)
local DEBOUNCE_NOTIFY = 500
local DEBOUNCE_JSONL = 300
local DEBOUNCE_BUFENTER = 150

-- Reusable timers (avoids handle leaks)
local debounce_timer = vim.uv.new_timer()
local jsonl_debounce = vim.uv.new_timer()
local bufenter_debounce = vim.uv.new_timer()
local pending_changes = {}

local function get_width()
	local w = require("cc-watcher").config.sidebar_width or 0.6
	-- If <= 1, treat as percentage of editor width
	if type(w) == "number" and w <= 1 then
		return math.floor(vim.o.columns * w)
	end
	return w
end

local function is_open()
	return sidebar_win and vim.api.nvim_win_is_valid(sidebar_win)
		and sidebar_buf and vim.api.nvim_buf_is_valid(sidebar_buf)
end

local relpath = util.relpath

local _sep_cache = { width = 0, str = "" }
local function get_separator(width)
	if _sep_cache.width ~= width then
		_sep_cache.width = width
		_sep_cache.str = string.rep("─", width)
	end
	return _sep_cache.str
end

--- Try to get a devicon for a filename
local _devicons = nil
local _devicons_checked = false

local function get_icon(name)
	if not _devicons_checked then
		_devicons_checked = true
		local ok, mod = pcall(require, "nvim-web-devicons")
		if ok then _devicons = mod end
	end
	if _devicons then
		local icon, hl = _devicons.get_icon(name, vim.fn.fnamemodify(name, ":e"), { default = true })
		return icon or "", hl
	end
	return "", nil
end

local function collect_files(session_files)
	local files = {}
	local seen = {}

	for filepath in pairs(watcher.get_changed_files()) do
		seen[filepath] = true
		files[#files + 1] = { abs = filepath, rel = relpath(filepath), live = true }
	end

	for _, filepath in ipairs(session_files or {}) do
		if not seen[filepath] then
			-- Only include session files that actually have changes vs git HEAD
			local old_text = util.get_old_text(filepath)
			local new_text = util.read_file(filepath) or ""
			local hunks = util.compute_hunks(old_text, new_text)
			if hunks and #hunks > 0 then
				files[#files + 1] = { abs = filepath, rel = relpath(filepath), live = false }
			end
		end
	end

	table.sort(files, function(a, b) return a.rel < b.rel end)
	return files
end

local function split_path(rel)
	local dir, name = rel:match("^(.+/)([^/]+)$")
	return dir or "", name or rel
end

--- Compute +N/-M stats for a file (from buffer or disk)
---@return number add, number del, string stats_str
local function file_stats(filepath)
	-- Try from loaded buffer first
	local bufnr = vim.fn.bufnr(filepath)
	if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
		local add, del = diff.file_stats(filepath, bufnr)
		if add > 0 or del > 0 then
			return add, del, "+" .. add .. " -" .. del
		end
		return 0, 0, ""
	end
	-- No buffer — compute from disk using git HEAD as baseline
	local old_text = util.get_old_text(filepath)
	local new_text = util.read_file(filepath) or ""
	if new_text ~= "" then
		local hunks = util.compute_hunks(old_text, new_text)
		if hunks then
			local add, del = util.hunk_stats(hunks)
			if add > 0 or del > 0 then
				return add, del, "+" .. add .. " -" .. del
			end
		end
	end
	return 0, 0, ""
end

--- Load commit history, cross-referencing with JSONL session files
local function load_history(session_files)
	if history_loaded then return end
	history_loaded = true

	local cwd = vim.uv.cwd()
	if not cwd then return end

	-- Build set of files Claude has edited (from JSONL)
	local claude_files = {}
	for _, fp in ipairs(session_files or {}) do
		local rel = util.relpath(fp, cwd)
		claude_files[rel] = true
	end
	if vim.tbl_count(claude_files) == 0 then return end

	-- Get recent commits with their changed files
	local log = vim.fn.systemlist("git log --pretty=format:'%h|%s|%cr' --name-only -50 2>/dev/null")
	if vim.v.shell_error ~= 0 then return end

	local commits = {}
	local current = nil
	for _, line in ipairs(log) do
		local hash, subject, date = line:match("^'?([a-f0-9]+)|(.+)|(.+)'?$")
		if hash then
			subject = subject:gsub("[%c]", "")
			date = date and date:gsub("[%c]", "") or ""
			current = { hash = hash, subject = subject, date = date, files = {} }
			commits[#commits + 1] = current
		elseif current and line ~= "" then
			current.files[#current.files + 1] = line
		end
	end

	-- Filter to commits that touched Claude-edited files
	history_commits = {}
	for _, c in ipairs(commits) do
		local claude_count = 0
		for _, f in ipairs(c.files) do
			if claude_files[f] then claude_count = claude_count + 1 end
		end
		if claude_count > 0 then
			history_commits[#history_commits + 1] = c
		end
	end
end

--- Get files and stats for a historical commit
local function commit_files(commit_hash)
	local cwd = vim.uv.cwd()
	local safe_hash = vim.fn.shellescape(commit_hash)
	local lines = vim.fn.systemlist("git diff-tree --no-commit-id --name-only -r " .. safe_hash .. " 2>/dev/null")
	if vim.v.shell_error ~= 0 then return {} end

	local files = {}
	for _, rel in ipairs(lines) do
		if rel ~= "" then
			files[#files + 1] = { abs = cwd .. "/" .. rel, rel = rel, live = false }
		end
	end
	table.sort(files, function(a, b) return a.rel < b.rel end)
	return files
end

--- Compute stats for a file in a historical commit (cached per commit)
local commit_stats_cache = {} -- hash -> { rel -> { add, del, stats } }

local function commit_file_stats(commit_hash, rel)
	if not commit_stats_cache[commit_hash] then
		-- Batch: get all numstats for this commit at once
		local safe_hash = vim.fn.shellescape(commit_hash)
		local output = vim.fn.systemlist("git diff " .. safe_hash .. "~1.." .. safe_hash .. " --numstat 2>/dev/null")
		local cache = {}
		for _, line in ipairs(output) do
			local a, d, f = line:match("^(%d+)%s+(%d+)%s+(.+)$")
			if a and d and f then
				a, d = tonumber(a), tonumber(d)
				local s = (a > 0 or d > 0) and ("+" .. a .. " -" .. d) or ""
				cache[f] = { a, d, s }
			end
		end
		commit_stats_cache[commit_hash] = cache
	end
	local entry = commit_stats_cache[commit_hash][rel]
	if entry then return entry[1], entry[2], entry[3] end
	return 0, 0, ""
end

local function do_render(session_files)
	if not is_open() then return end

	-- Load history in background (once)
	load_history(session_files)

	local WIDTH = get_width()
	line_to_file = {}

	-- Find the file open in the main editor window
	local current_file = nil
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if win ~= sidebar_win then
			local buf = vim.api.nvim_win_get_buf(win)
			local name = vim.api.nvim_buf_get_name(buf)
			if name ~= "" and vim.bo[buf].buftype == "" then
				current_file = name
				break
			end
		end
	end

	local lines = {}
	local hls = {}
	local total_add, total_del = 0, 0
	local current_file_row = nil

	-- Determine which files to show: current or history
	local viewing_commit = nil
	if history_idx > 0 and history_idx <= #history_commits then
		viewing_commit = history_commits[history_idx]
		displayed_files = commit_files(viewing_commit.hash)
	else
		displayed_files = collect_files(session_files)
	end

	-- Header
	local filter = not viewing_commit and session.get_session_filter() or nil
	lines[1] = filter and " 󰚩 Claude Code 󰈲" or " 󰚩 Claude Code"
	hls[#hls + 1] = { 0, "ClaudeHeader" }

	if viewing_commit then
		-- History mode header
		local date_suffix = viewing_commit.date ~= "" and ("  " .. viewing_commit.date) or ""
		local label = "  " .. viewing_commit.hash .. " " .. viewing_commit.subject .. date_suffix
		if #label > WIDTH then label = label:sub(1, WIDTH - 1) .. "…" end
		lines[2] = label
		hls[#hls + 1] = { 1, "ClaudeSession" }
	else
		local cwd = vim.uv.cwd()
		if filter then
			-- Filtered to a specific conversation — show its label
			local encoded = cwd:gsub("[/_]", "-")
			local jsonl = vim.fn.expand("~/.claude/projects") .. "/" .. encoded .. "/" .. filter .. ".jsonl"
			local stat = vim.uv.fs_stat(jsonl)
			if stat then
				local lbl = session.get_conversation_label(jsonl)
				if lbl == "" then lbl = filter:sub(1, 8) end
				local status = "  " .. lbl
				if #status > WIDTH then status = status:sub(1, WIDTH - 1) .. "…" end
				lines[2] = status
				hls[#hls + 1] = { 1, "ClaudeActive" }
			else
				lines[2] = "  filtered (conversation ended)"
				hls[#hls + 1] = { 1, "ClaudeInactive" }
			end
		else
			local active = session.find_active_session(cwd)
			if active then
				local all = session.find_all_active_sessions(cwd)
				if #all > 1 then
					lines[2] = "  " .. #all .. " sessions active  S pick"
					hls[#hls + 1] = { 1, "ClaudeActive" }
				else
					lines[2] = "  session active"
					hls[#hls + 1] = { 1, "ClaudeActive" }
				end
			else
				lines[2] = "  no session"
				hls[#hls + 1] = { 1, "ClaudeInactive" }
			end
		end
	end

	-- History navigation hint
	if #history_commits > 0 then
		local nav = viewing_commit
			and ("  [" .. history_idx .. "/" .. #history_commits .. "]  ]g/[g nav  H back")
			or ("  " .. #history_commits .. " commits  H history")
		lines[3] = nav
		hls[#hls + 1] = { 2, "ClaudeHelp" }
	else
		lines[3] = get_separator(WIDTH)
		hls[#hls + 1] = { 2, "ClaudeSep" }
	end

	if #displayed_files == 0 then
		lines[4] = ""
		lines[5] = "  Waiting for changes..."
		hls[#hls + 1] = { 4, "ClaudeInactive" }
	else
		-- Find the most recently modified file by mtime (always accurate)
		local best_mtime, best_file = 0, nil
		for _, f in ipairs(displayed_files) do
			local st = vim.uv.fs_stat(f.abs)
			if st and st.mtime.sec > best_mtime then
				best_mtime = st.mtime.sec
				best_file = f.abs
			end
		end
		if best_file then latest_changed_file = best_file end

		-- Flat list: full relative path per line
		for _, file in ipairs(displayed_files) do
			local _, name = split_path(file.rel)
			local icon, icon_hl = get_icon(name)

			local is_latest_file = not viewing_commit and latest_changed_file and file.abs == latest_changed_file
			local indicator, ind_hl
			if viewing_commit then
				indicator = "◆"
				ind_hl = "ClaudeSession"
			elseif is_latest_file then
				indicator = "▶"
				ind_hl = "ClaudeFileLatest"
			else
				indicator = file.live and "●" or "○"
				ind_hl = file.live and "ClaudeLive" or "ClaudeSession"
			end

			local prefix = "  " .. indicator .. " " .. icon .. " "
			local add, del, stats
			if viewing_commit then
				add, del, stats = commit_file_stats(viewing_commit.hash, file.rel)
			else
				add, del, stats = file_stats(file.abs)
			end
			total_add = total_add + add
			total_del = total_del + del

			local line = prefix .. file.rel
			if stats ~= "" then
				local padding = WIDTH - vim.api.nvim_strwidth(line) - vim.api.nvim_strwidth(stats) - 1
				if padding > 1 then
					line = line .. string.rep(" ", padding) .. stats
				else
					line = line .. " " .. stats
				end
			end

			table.insert(lines, line)
			line_to_file[#lines] = file

			local cur_ln = #lines - 1
			-- Indicator highlight
			hls[#hls + 1] = { cur_ln, ind_hl, 2, 2 + #indicator }
			-- Icon highlight
			if icon_hl then
				local icon_start = 2 + #indicator + 1
				hls[#hls + 1] = { cur_ln, icon_hl, icon_start, icon_start + #icon }
			end
			-- Path highlights: current file > latest changed > normal
			local is_current = current_file and file.abs == current_file
			local is_latest = not viewing_commit and latest_changed_file and file.abs == latest_changed_file
			if is_current then
				hls[#hls + 1] = { cur_ln, "ClaudeFileCurrent", 0, -1 }
				current_file_row = #lines
			elseif is_latest then
				hls[#hls + 1] = { cur_ln, "ClaudeFileLatest", 0, -1 }
			else
				hls[#hls + 1] = { cur_ln, "ClaudeFile", #prefix, #prefix + #file.rel }
			end
			-- Stats
			if stats ~= "" then
				hls[#hls + 1] = { cur_ln, "ClaudeStats", #line - #stats, -1 }
			end
		end
	end

	-- Footer
	table.insert(lines, "")
	table.insert(lines, get_separator(WIDTH))
	hls[#hls + 1] = { #lines - 1, "ClaudeSep" }

	-- Summary line
	local summary = "  " .. #displayed_files .. " files"
	if total_add > 0 or total_del > 0 then
		summary = summary .. "  +" .. total_add .. " -" .. total_del
	end
	table.insert(lines, summary)
	hls[#hls + 1] = { #lines - 1, "ClaudeCount" }

	table.insert(lines, "  g? help")
	hls[#hls + 1] = { #lines - 1, "ClaudeHelp" }

	-- Write to buffer
	vim.bo[sidebar_buf].modifiable = true
	vim.api.nvim_buf_set_lines(sidebar_buf, 0, -1, false, lines)
	vim.bo[sidebar_buf].modifiable = false

	-- Apply highlights using extmarks (not deprecated buf_add_highlight)
	-- Higher priority for file-level highlights so they aren't overridden
	local high_pri = { ClaudeFileLatest = true, ClaudeFileCurrent = true }
	vim.api.nvim_buf_clear_namespace(sidebar_buf, ns, 0, -1)
	for _, h in ipairs(hls) do
		pcall(vim.api.nvim_buf_set_extmark, sidebar_buf, ns, h[1], h[3] or 0, {
			end_col = (h[4] and h[4] >= 0) and h[4] or nil,
			hl_group = h[2],
			hl_eol = (h[4] or -1) == -1,
			priority = high_pri[h[2]] and 200 or 100,
		})
	end

	-- Move cursor to the current file's line
	if current_file_row and sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
		pcall(vim.api.nvim_win_set_cursor, sidebar_win, { current_file_row, 0 })
	end
end

function M.render()
	if not is_open() then return end

	session.get_claude_edited_files_async(function(files)
		vim.schedule(function() do_render(files) end)
	end)
end

local function file_at_cursor()
	if not is_open() then return nil end
	local row = vim.api.nvim_win_get_cursor(sidebar_win)[1]
	return line_to_file[row]
end

local function show_help()
	local help = {
		"╭────────────────────────────────╮",
		"│  cc-watcher.nvim               │",
		"│                                │",
		"│  Sidebar:                      │",
		"│    <CR>/d/o Open file with diff │",
		"│    S       Pick session        │",
		"│    r       Refresh             │",
		"│    H       Toggle history      │",
		"│    ]g/[g   Next/prev commit    │",
		"│    q       Close sidebar       │",
		"│    g?      Toggle help         │",
		"│                                │",
		"│  In diff view:                 │",
		"│    ]c      Next hunk           │",
		"│    [c      Previous hunk       │",
		"│    cr      Revert hunk         │",
		"│    <leader>cd  Toggle diff     │",
		"│                                │",
		"│  Integrations (opt-in):        │",
		"│    :ClaudeSnacks [hunks]       │",
		"│    :ClaudeFzf [hunks]          │",
		"│    :ClaudeTrouble              │",
		"│    :ClaudeDiffview [file]      │",
		"│    :ClaudeFlash                │",
		"│    :ClaudeSession              │",
		"│                                │",
		"│  ▶ latest  ● live  ○ session   │",
		"╰────────────────────────────────╯",
	}
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, help)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = 34,
		height = #help,
		row = math.floor((vim.o.lines - #help) / 2),
		col = math.floor((vim.o.columns - 34) / 2),
		style = "minimal",
		border = "none",
	})

	vim.keymap.set("n", "q", function() vim.api.nvim_win_close(win, true) end, { buffer = buf, nowait = true })
	vim.keymap.set("n", "g?", function() vim.api.nvim_win_close(win, true) end, { buffer = buf, nowait = true })
	vim.keymap.set("n", "<Esc>", function() vim.api.nvim_win_close(win, true) end, { buffer = buf, nowait = true })
end

function M.open()
	if is_open() then
		M.render()
		return
	end

	highlights.setup()

	sidebar_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[sidebar_buf].buftype = "nofile"
	vim.bo[sidebar_buf].bufhidden = "wipe"
	vim.bo[sidebar_buf].swapfile = false
	vim.bo[sidebar_buf].filetype = "claude-sidebar"

	vim.cmd("topleft vsplit")
	sidebar_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(sidebar_win, sidebar_buf)
	vim.api.nvim_win_set_width(sidebar_win, get_width())

	local wo = vim.wo[sidebar_win]
	wo.number = false
	wo.relativenumber = false
	wo.signcolumn = "no"
	wo.cursorcolumn = false
	wo.foldcolumn = "0"
	wo.wrap = false
	wo.winfixwidth = true
	wo.cursorline = true
	wo.statusline = " "

	local opts = { buffer = sidebar_buf, nowait = true, silent = true }

	local function open_with_diff()
		local f = file_at_cursor()
		if not f then
			vim.notify("No file on this line", vim.log.levels.INFO)
			return
		end
		if vim.fn.winnr("$") <= 1 then
			vim.cmd("wincmd v")
		end
		vim.cmd("wincmd p")

		if history_idx > 0 and history_idx <= #history_commits then
			-- History mode: open diffview for this commit's version
			local commit = history_commits[history_idx]
			local dv_ok, dv = pcall(require, "cc-watcher.diffview")
			if dv_ok then
				dv.open_commit_file(commit.hash, f.abs)
			else
				vim.cmd("edit " .. vim.fn.fnameescape(f.abs))
				vim.notify("Commit " .. commit.hash .. ": " .. f.rel, vim.log.levels.INFO)
			end
		else
			vim.cmd("edit " .. vim.fn.fnameescape(f.abs))
			require("cc-watcher.diff").show(f.abs, { jump = true })
		end
	end

	vim.keymap.set("n", "<CR>", open_with_diff, opts)
	vim.keymap.set("n", "d", open_with_diff, opts)
	vim.keymap.set("n", "o", open_with_diff, opts)
	vim.keymap.set("n", "r", function()
		history_loaded = false -- force reload
		M.render()
	end, opts)
	vim.keymap.set("n", "q", function() M.close() end, opts)
	vim.keymap.set("n", "g?", show_help, opts)

	-- History navigation
	vim.keymap.set("n", "H", function()
		if history_idx == 0 and #history_commits > 0 then
			history_idx = 1
		else
			history_idx = 0
		end
		M.render()
	end, opts)
	vim.keymap.set("n", "]g", function()
		if history_idx > 0 and history_idx < #history_commits then
			history_idx = history_idx + 1
			M.render()
		end
	end, opts)
	vim.keymap.set("n", "[g", function()
		if history_idx > 0 then
			history_idx = history_idx - 1
			M.render()
		end
	end, opts)

	-- Session picker
	vim.keymap.set("n", "S", function()
		session.pick(function()
			history_loaded = false
			M.render()
		end)
	end, opts)

	M.render()
	vim.cmd("wincmd p")
end

function M.close()
	if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
		vim.api.nvim_win_close(sidebar_win, true)
	end
	sidebar_win = nil
	sidebar_buf = nil
end

function M.toggle()
	if is_open() then M.close() else M.open() end
end

--- Debug: show sidebar state
function M.debug()
	print("latest_changed_file: " .. tostring(latest_changed_file))
	print("displayed_files: " .. #displayed_files)
	print("history_idx: " .. history_idx)
	for i, f in ipairs(displayed_files) do
		local st = vim.uv.fs_stat(f.abs)
		local mtime = st and st.mtime.sec or 0
		local marker = (f.abs == latest_changed_file) and " <<< LATEST" or ""
		print(string.format("  %d. %s (mtime=%d)%s", i, f.rel, mtime, marker))
	end
end

local function flush_notifications()
	if #pending_changes == 0 then return end
	if #pending_changes == 1 then
		vim.notify("󰚩 " .. pending_changes[1], vim.log.levels.INFO, { title = "Claude" })
	else
		vim.notify("󰚩 " .. #pending_changes .. " files changed", vim.log.levels.INFO, { title = "Claude" })
	end
	pending_changes = {}
end

function M.setup()
	watcher.on_change(function(filepath, rel)
		latest_changed_file = filepath
		pending_changes[#pending_changes + 1] = rel
		debounce_timer:stop()
		debounce_timer:start(DEBOUNCE_NOTIFY, 0, vim.schedule_wrap(flush_notifications))

		if is_open() then M.render() end

		local bufnr = vim.fn.bufnr(filepath)
		if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
			vim.schedule(function()
				diff.apply_signs(bufnr, filepath)
			end)
		end
	end)

	-- Event-driven sidebar refresh on JSONL change
	session.on_jsonl_change(function()
		-- Force re-seed of latest_changed_file on next render
		latest_changed_file = nil
		if not is_open() then return end
		jsonl_debounce:stop()
		jsonl_debounce:start(DEBOUNCE_JSONL, 0, vim.schedule_wrap(function() M.render() end))
	end)

	-- Re-render sidebar when switching buffers to update current file highlight
	vim.api.nvim_create_autocmd("BufEnter", {
		group = augroup,
		callback = function()
			if is_open() then
				bufenter_debounce:stop()
				bufenter_debounce:start(DEBOUNCE_BUFENTER, 0, vim.schedule_wrap(function() M.render() end))
			end
		end,
	})
end

return M
