-- diffview.lua — Side-by-side diff view for Claude Code changes
-- Snapshot (pre-Claude) vs current file state. Uses vim diff mode.
-- Works standalone; no diffview.nvim dependency required.

local M = {}

local relpath = require("cc-watcher.util").relpath

-- Track state for the diff tab so we can close it cleanly
local state = {
	tabpage = nil,
	bufs = {},  -- scratch buffers we created
}

--- Collect all files Claude has changed (watcher + session)
---@param callback fun(files: { abs: string, rel: string }[])
local function collect_changed_files(callback)
	require("cc-watcher.util").collect_files(function(files, cwd)
		callback(files)
	end)
end

--- Create a readonly scratch buffer with pre-edit content (git HEAD or snapshot fallback)
---@param filepath string absolute path
---@return number|nil bufnr
local function create_before_buf(filepath)
	local util = require("cc-watcher.util")

	-- Get pre-edit content: git HEAD first, snapshot fallback
	local old_text = util.get_old_text(filepath)
	if old_text == "" then return nil end

	local lines = vim.split(old_text, "\n", { plain = true })
	-- Remove trailing empty string from split
	if #lines > 0 and lines[#lines] == "" then
		table.remove(lines)
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = false

	-- Set filetype for syntax highlighting
	local ft = vim.filetype.match({ filename = filepath })
	if ft then vim.bo[buf].filetype = ft end

	-- Give it a meaningful name
	local rel = relpath(filepath)
	pcall(vim.api.nvim_buf_set_name, buf, "claude://" .. rel .. " (before)")

	return buf
end

--- Open a side-by-side diff for a single file (snapshot vs current)
---@param filepath string absolute path
function M.open_file(filepath)
	filepath = vim.fn.fnamemodify(filepath, ":p")

	-- Check file exists on disk
	local stat = vim.uv.fs_stat(filepath)
	if not stat then
		vim.notify("File not found: " .. relpath(filepath), vim.log.levels.WARN)
		return
	end

	local before_buf = create_before_buf(filepath)
	if not before_buf then
		vim.notify("No git history for " .. relpath(filepath), vim.log.levels.WARN)
		return
	end

	-- Open snapshot buffer on the left
	vim.cmd("tabnew")
	local tab = vim.api.nvim_get_current_tabpage()
	vim.api.nvim_win_set_buf(0, before_buf)
	vim.cmd("diffthis")

	-- Open current file on the right
	vim.cmd("vertical rightbelow split " .. vim.fn.fnameescape(filepath))
	vim.cmd("diffthis")

	-- Store state for cleanup
	state.tabpage = tab
	state.bufs = { before_buf }

	-- Set up q to close the diff tab
	local function close_tab()
		M.close()
	end

	vim.keymap.set("n", "q", close_tab, { buffer = before_buf, nowait = true, silent = true })

	local cur_buf = vim.api.nvim_get_current_buf()
	if cur_buf ~= before_buf then
		vim.keymap.set("n", "q", close_tab, { buffer = cur_buf, nowait = true, silent = true })
	end
end

--- Open diff views for all changed files in a new tab
--- Each file pair is stacked: snapshot (left) vs current (right)
--- Navigate between files with ]f / [f
function M.open()
	collect_changed_files(function(files)
		vim.schedule(function()
			if #files == 0 then
				vim.notify("No Claude changes to diff", vim.log.levels.INFO)
				return
			end

			-- If only one file, just open it directly
			if #files == 1 then
				M.open_file(files[1].abs)
				return
			end

			-- Open a new tab for the diff session
			vim.cmd("tabnew")
			local tab = vim.api.nvim_get_current_tabpage()
			state.tabpage = tab
			state.bufs = {}

			-- Start with the first file
			local idx = 1
			local scratch_bufs = {}

			-- Persistent windows: left = before, right = current
			local left_win = vim.api.nvim_get_current_win()
			vim.cmd("vertical rightbelow split")
			local right_win = vim.api.nvim_get_current_win()

			local function show_file(i)
				if i < 1 or i > #files then return end
				idx = i

				if not vim.api.nvim_win_is_valid(left_win) or not vim.api.nvim_win_is_valid(right_win) then
					return
				end

				local file = files[idx]
				local before_buf = create_before_buf(file.abs)

				if not before_buf then
					vim.notify("No git history for " .. file.rel, vim.log.levels.WARN)
					return
				end

				-- Turn off diff in both windows
				vim.api.nvim_win_call(left_win, function() vim.cmd("diffoff") end)
				vim.api.nvim_win_call(right_win, function() vim.cmd("diffoff") end)

				-- Clean up old scratch buffers
				for _, b in ipairs(scratch_bufs) do
					if vim.api.nvim_buf_is_valid(b) then
						pcall(vim.api.nvim_buf_delete, b, { force = true })
					end
				end
				scratch_bufs = { before_buf }

				-- Left: before content
				vim.api.nvim_win_set_buf(left_win, before_buf)
				vim.api.nvim_win_call(left_win, function() vim.cmd("diffthis") end)

				-- Right: current file
				vim.cmd("edit " .. vim.fn.fnameescape(file.abs))
				local cur_buf = vim.api.nvim_get_current_buf()
				vim.api.nvim_win_set_buf(right_win, cur_buf)
				vim.api.nvim_set_current_win(right_win)
				vim.cmd("diffthis")

				vim.notify(string.format(" [%d/%d] %s", idx, #files, file.rel), vim.log.levels.INFO)

				-- Set up navigation keymaps on both buffers
				local function setup_keys(bufnr)
					local opts = { buffer = bufnr, nowait = true, silent = true }
					vim.keymap.set("n", "]f", function()
						if idx < #files then show_file(idx + 1) end
					end, opts)
					vim.keymap.set("n", "[f", function()
						if idx > 1 then show_file(idx - 1) end
					end, opts)
					vim.keymap.set("n", "q", function() M.close() end, opts)
				end

				setup_keys(before_buf)
				if cur_buf ~= before_buf then
					setup_keys(cur_buf)
				end
			end

			show_file(1)
			state.bufs = scratch_bufs
		end)
	end)
end

--- Close the diff view tab
function M.close()
	if not state.tabpage then return end

	-- Check if the tabpage is still valid
	local valid = false
	for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
		if tp == state.tabpage then
			valid = true
			break
		end
	end

	if valid then
		-- Turn off diff mode in all windows of the tab
		local wins = vim.api.nvim_tabpage_list_wins(state.tabpage)
		for _, w in ipairs(wins) do
			if vim.api.nvim_win_is_valid(w) then
				vim.api.nvim_win_call(w, function()
					vim.cmd("diffoff")
				end)
			end
		end

		-- Close the tab (only if it's not the last one)
		if #vim.api.nvim_list_tabpages() > 1 then
			local cur_tab = vim.api.nvim_get_current_tabpage()
			if cur_tab == state.tabpage then
				vim.cmd("tabclose")
			else
				-- Switch to it, then close
				local tab_nr = vim.api.nvim_tabpage_get_number(state.tabpage)
				vim.cmd(tab_nr .. "tabclose")
			end
		else
			-- Last tab — just clean up the windows and buffers
			local wins = vim.api.nvim_tabpage_list_wins(state.tabpage)
			for i = #wins, 2, -1 do
				if vim.api.nvim_win_is_valid(wins[i]) then
					vim.api.nvim_win_close(wins[i], true)
				end
			end
		end
	end

	-- Clean up scratch buffers
	for _, buf in ipairs(state.bufs) do
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end

	state.tabpage = nil
	state.bufs = {}
end

return M
