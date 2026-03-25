-- sidebar.lua — Sidebar showing files Claude Code has touched

local M = {}

local watcher = require("cc-watcher.watcher")
local session = require("cc-watcher.session")
local highlights = require("cc-watcher.highlights")

local sidebar_buf = nil
local sidebar_win = nil

local displayed_files = {}
local ns = vim.api.nvim_create_namespace("claude_sidebar")

-- Notification debounce state
local pending_changes = {}
local debounce_timer = nil

local function get_width()
	local ok, cfg = pcall(require, "claude-code")
	return ok and cfg.config and cfg.config.sidebar_width or 36
end

local function is_open()
	return sidebar_win and vim.api.nvim_win_is_valid(sidebar_win)
		and sidebar_buf and vim.api.nvim_buf_is_valid(sidebar_buf)
end

local function relpath(filepath)
	local cwd = vim.fn.getcwd()
	if filepath:sub(1, #cwd) == cwd then
		return filepath:sub(#cwd + 2)
	end
	return filepath
end

local function collect_files(session_files)
	local files = {}
	local seen = {}

	for filepath in pairs(watcher.get_changed_files()) do
		seen[filepath] = true
		table.insert(files, { abs = filepath, rel = relpath(filepath), live = true })
	end

	for _, filepath in ipairs(session_files or {}) do
		if not seen[filepath] then
			table.insert(files, { abs = filepath, rel = relpath(filepath), live = false })
		end
	end

	table.sort(files, function(a, b) return a.rel < b.rel end)
	return files
end

local function split_path(rel)
	local dir, name = rel:match("^(.+/)([^/]+)$")
	return dir or "", name or rel
end

local function do_render(session_files)
	if not is_open() then return end

	local WIDTH = get_width()
	displayed_files = collect_files(session_files)

	local lines = {}
	local hls = {}

	lines[1] = "  Claude Code"
	hls[#hls + 1] = { 0, "ClaudeHeader" }

	local cwd = vim.fn.getcwd()
	local active = session.find_active_session(cwd)
	if active then
		lines[2] = "  session active"
		hls[#hls + 1] = { 1, "ClaudeActive" }
	else
		lines[2] = "  no session"
		hls[#hls + 1] = { 1, "ClaudeInactive" }
	end

	lines[3] = string.rep("─", WIDTH)
	hls[#hls + 1] = { 2, "ClaudeSep" }

	if #displayed_files == 0 then
		lines[4] = ""
		lines[5] = "  Waiting for changes..."
		hls[#hls + 1] = { 4, "ClaudeInactive" }
	else
		local header_n = #lines
		for i, file in ipairs(displayed_files) do
			local indicator = file.live and "● " or "○ "
			local dir, name = split_path(file.rel)

			local line = indicator .. dir .. name
			if #line > WIDTH then
				local avail = WIDTH - #indicator - #name - 2
				if avail > 3 then
					dir = "…" .. dir:sub(-(avail - 1))
				else
					dir = ""
				end
				line = indicator .. dir .. name
			end

			table.insert(lines, line)

			local ln = header_n + i - 1
			hls[#hls + 1] = { ln, file.live and "ClaudeLive" or "ClaudeSession", 0, #indicator }
			if dir ~= "" then
				hls[#hls + 1] = { ln, "ClaudeDir", #indicator, #indicator + #dir }
			end
			hls[#hls + 1] = { ln, "ClaudeFile", #indicator + #dir, -1 }
		end
	end

	table.insert(lines, "")
	table.insert(lines, string.rep("─", WIDTH))
	hls[#hls + 1] = { #lines - 1, "ClaudeSep" }

	local live_n = 0
	for _, f in ipairs(displayed_files) do
		if f.live then live_n = live_n + 1 end
	end
	local session_n = #displayed_files - live_n
	local count_parts = {}
	if live_n > 0 then table.insert(count_parts, live_n .. " live") end
	if session_n > 0 then table.insert(count_parts, session_n .. " session") end
	table.insert(lines, "  " .. (#count_parts > 0 and table.concat(count_parts, " / ") or "0 files"))
	hls[#hls + 1] = { #lines - 1, "ClaudeCount" }

	table.insert(lines, "  <CR> diff  o open  r refresh  q quit")
	hls[#hls + 1] = { #lines - 1, "ClaudeHelp" }

	vim.bo[sidebar_buf].modifiable = true
	vim.api.nvim_buf_set_lines(sidebar_buf, 0, -1, false, lines)
	vim.bo[sidebar_buf].modifiable = false

	vim.api.nvim_buf_clear_namespace(sidebar_buf, ns, 0, -1)
	for _, h in ipairs(hls) do
		pcall(vim.api.nvim_buf_add_highlight, sidebar_buf, ns, h[2], h[1], h[3] or 0, h[4] or -1)
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
	local idx = row - 3
	if idx >= 1 and idx <= #displayed_files then
		return displayed_files[idx]
	end
	return nil
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

	-- Open file with inline diff
	local function open_with_diff()
		local f = file_at_cursor()
		if f then
			vim.cmd("wincmd p")
			vim.cmd("edit " .. vim.fn.fnameescape(f.abs))
			require("cc-watcher.diff").show(f.abs)
		end
	end

	-- Open file without diff
	local function open_plain()
		local f = file_at_cursor()
		if f then
			vim.cmd("wincmd p")
			vim.cmd("edit " .. vim.fn.fnameescape(f.abs))
		end
	end

	vim.keymap.set("n", "<CR>", open_with_diff, opts)
	vim.keymap.set("n", "d", open_with_diff, opts)
	vim.keymap.set("n", "o", open_plain, opts)
	vim.keymap.set("n", "r", function() M.render() end, opts)
	vim.keymap.set("n", "q", function() M.close() end, opts)

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

--- Flush pending change notifications as a single batch
local function flush_notifications()
	if #pending_changes == 0 then return end

	if #pending_changes == 1 then
		vim.notify("  " .. pending_changes[1], vim.log.levels.INFO, { title = "Claude" })
	else
		vim.notify(
			"  " .. #pending_changes .. " files changed",
			vim.log.levels.INFO,
			{ title = "Claude" }
		)
	end

	pending_changes = {}
end

function M.setup()
	watcher.on_change(function(filepath, rel)
		-- Debounce notifications: batch within 500ms
		table.insert(pending_changes, rel)
		if debounce_timer then
			debounce_timer:stop()
		end
		debounce_timer = vim.uv.new_timer()
		debounce_timer:start(500, 0, vim.schedule_wrap(function()
			flush_notifications()
			debounce_timer:close()
			debounce_timer = nil
		end))

		if is_open() then M.render() end

		-- Apply sign indicators on open buffers
		for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_loaded(bufnr)
				and vim.api.nvim_buf_get_name(bufnr) == filepath then
				vim.schedule(function()
					require("cc-watcher.diff").apply_signs(bufnr, filepath)
				end)
				break
			end
		end
	end)
end

return M
