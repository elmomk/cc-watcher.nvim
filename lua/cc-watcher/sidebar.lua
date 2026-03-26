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
local ns = vim.api.nvim_create_namespace("claude_sidebar")
local augroup = vim.api.nvim_create_augroup("ClaudeSidebar", { clear = true })

-- Reusable timers (avoids handle leaks)
local debounce_timer = vim.uv.new_timer()
local jsonl_debounce = vim.uv.new_timer()
local bufenter_debounce = vim.uv.new_timer()
local pending_changes = {}

local function get_width()
	return require("cc-watcher").config.sidebar_width or 36
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
			files[#files + 1] = { abs = filepath, rel = relpath(filepath), live = false }
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

local function do_render(session_files)
	if not is_open() then return end

	local WIDTH = get_width()
	displayed_files = collect_files(session_files)
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

	-- Header
	lines[1] = " 󰚩 Claude Code"
	hls[#hls + 1] = { 0, "ClaudeHeader" }

	local cwd = vim.uv.cwd()
	local active = session.find_active_session(cwd)
	if active then
		lines[2] = "  session active"
		hls[#hls + 1] = { 1, "ClaudeActive" }
	else
		lines[2] = "  no session"
		hls[#hls + 1] = { 1, "ClaudeInactive" }
	end

	lines[3] = get_separator(WIDTH)
	hls[#hls + 1] = { 2, "ClaudeSep" }

	if #displayed_files == 0 then
		lines[4] = ""
		lines[5] = "  Waiting for changes..."
		hls[#hls + 1] = { 4, "ClaudeInactive" }
	else
		-- Group files by directory
		local groups = {}
		local group_order = {}
		for _, file in ipairs(displayed_files) do
			local dir, _ = split_path(file.rel)
			if not groups[dir] then
				groups[dir] = {}
				group_order[#group_order + 1] = dir
			end
			groups[dir][#groups[dir] + 1] = file
		end

		for _, dir in ipairs(group_order) do
			local ln = #lines

			-- Directory header (skip for root-level files)
			if dir ~= "" then
				table.insert(lines, "  " .. dir)
				hls[#hls + 1] = { ln, "ClaudeDir" }
				ln = #lines
			end

			-- Files in this directory
			for _, file in ipairs(groups[dir]) do
				local _, name = split_path(file.rel)
				local icon, icon_hl = get_icon(name)
				local indicator = file.live and "●" or "○"
				local ind_hl = file.live and "ClaudeLive" or "ClaudeSession"

				-- Build the line: "  ● 󰈙 filename.rs       +3 -1"
				local indent = dir ~= "" and "    " or "  "
				local prefix = indent .. indicator .. " " .. icon .. " "
				local add, del, stats = file_stats(file.abs)
				total_add = total_add + add
				total_del = total_del + del

				local line = prefix .. name
				if stats ~= "" then
					local padding = WIDTH - vim.api.nvim_strwidth(line) - vim.api.nvim_strwidth(stats) - 1
					if padding > 0 then
						line = line .. string.rep(" ", padding) .. stats
					end
				end

				table.insert(lines, line)
				line_to_file[#lines] = file

				local cur_ln = #lines - 1
				-- Indicator highlight
				hls[#hls + 1] = { cur_ln, ind_hl, #indent, #indent + #indicator }
				-- Icon highlight (if devicons provides one)
				if icon_hl then
					local icon_start = #indent + #indicator + 1
					hls[#hls + 1] = { cur_ln, icon_hl, icon_start, icon_start + #icon }
				end
				-- Filename (bold highlight if it's the currently open file)
				local is_current = current_file and file.abs == current_file
				if is_current then
					hls[#hls + 1] = { cur_ln, "ClaudeFileCurrent", 0, -1 }
					current_file_row = #lines
				end
				local file_hl = is_current and "ClaudeFileCurrent" or "ClaudeFile"
				hls[#hls + 1] = { cur_ln, file_hl, #prefix, #prefix + #name }
				-- Stats
				if stats ~= "" then
					hls[#hls + 1] = { cur_ln, "ClaudeStats", #line - #stats, -1 }
				end
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
	vim.api.nvim_buf_clear_namespace(sidebar_buf, ns, 0, -1)
	for _, h in ipairs(hls) do
		pcall(vim.api.nvim_buf_set_extmark, sidebar_buf, ns, h[1], h[3] or 0, {
			end_col = (h[4] and h[4] >= 0) and h[4] or nil,
			hl_group = h[2],
			hl_eol = (h[4] or -1) == -1,
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
		"│    r       Refresh             │",
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
		"│                                │",
		"│  ● live change  ○ from session │",
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
		vim.cmd("edit " .. vim.fn.fnameescape(f.abs))
		require("cc-watcher.diff").show(f.abs, { jump = true })
	end

	vim.keymap.set("n", "<CR>", open_with_diff, opts)
	vim.keymap.set("n", "d", open_with_diff, opts)
	vim.keymap.set("n", "o", open_with_diff, opts)
	vim.keymap.set("n", "r", function() M.render() end, opts)
	vim.keymap.set("n", "q", function() M.close() end, opts)
	vim.keymap.set("n", "g?", show_help, opts)

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
		pending_changes[#pending_changes + 1] = rel
		debounce_timer:stop()
		debounce_timer:start(500, 0, vim.schedule_wrap(flush_notifications))

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
		if not is_open() then return end
		jsonl_debounce:stop()
		jsonl_debounce:start(300, 0, vim.schedule_wrap(function() M.render() end))
	end)

	-- Re-render sidebar when switching buffers to update current file highlight
	vim.api.nvim_create_autocmd("BufEnter", {
		group = augroup,
		callback = function()
			if is_open() then
				bufenter_debounce:stop()
				bufenter_debounce:start(150, 0, vim.schedule_wrap(function() M.render() end))
			end
		end,
	})
end

return M
