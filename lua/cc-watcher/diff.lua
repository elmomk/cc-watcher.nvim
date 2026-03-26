-- diff.lua — Inline diff highlighting for Claude Code changes
-- Toggle on/off. Sign column. Hunk navigation. Hunk revert.

local M = {}

local snapshots = require("cc-watcher.snapshots")
local highlights = require("cc-watcher.highlights")

local ns = vim.api.nvim_create_namespace("claude_diff")
local sign_ns = vim.api.nvim_create_namespace("claude_diff_signs")
local flash_ns = vim.api.nvim_create_namespace("claude_flash")

-- bufnr -> { hunks, hunk_lines, filepath }
local active_diffs = {}

local augroup = vim.api.nvim_create_augroup("ClaudeDiffCleanup", { clear = true })

vim.api.nvim_create_autocmd("BufWipeout", {
	group = augroup,
	callback = function(args) active_diffs[args.buf] = nil end,
})

local function relpath(filepath)
	local cwd = vim.fn.getcwd()
	if filepath:sub(1, #cwd) == cwd then return filepath:sub(#cwd + 2) end
	return filepath
end

--- Get the file path relative to its git repo root (handles worktrees)
local function git_relpath(filepath)
	local dir = vim.fn.fnamemodify(filepath, ":h")
	local root = vim.fn.systemlist("git -C " .. vim.fn.shellescape(dir) .. " rev-parse --show-toplevel 2>/dev/null")
	if vim.v.shell_error == 0 and root[1] then
		local git_root = root[1]
		if filepath:sub(1, #git_root) == git_root then
			return filepath:sub(#git_root + 2), dir
		end
	end
	return relpath(filepath), dir
end

local function git_show_head(filepath)
	local rel, dir = git_relpath(filepath)
	return vim.fn.systemlist("git -C " .. vim.fn.shellescape(dir) .. " show HEAD:" .. vim.fn.shellescape(rel) .. " 2>/dev/null")
end

local function get_before_lines(filepath)
	-- Always prefer git HEAD — snapshots are taken on BufReadPost which is
	-- after Claude has already edited the file, so they contain post-edit content.
	local lines = git_show_head(filepath)
	if vim.v.shell_error == 0 and #lines > 0 then return lines end

	local snap = snapshots.get(filepath)
	if snap then return snap.lines end
	return nil
end

local function get_before_raw(filepath)
	local lines = git_show_head(filepath)
	if vim.v.shell_error == 0 and #lines > 0 then
		return table.concat(lines, "\n") .. "\n"
	end

	local snap = snapshots.get(filepath)
	if snap then return snap.raw end
	return nil
end

local function compute_hunks(filepath, bufnr)
	local old_text = get_before_raw(filepath)
	if not old_text then return nil end
	-- Normalize: ensure trailing newline
	if old_text:sub(-1) ~= "\n" then old_text = old_text .. "\n" end
	local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local new_text = table.concat(current_lines, "\n") .. "\n"
	return vim.diff(old_text, new_text, { result_type = "indices", algorithm = "histogram" })
end

local function clear(bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	vim.api.nvim_buf_clear_namespace(bufnr, sign_ns, 0, -1)
	pcall(vim.keymap.del, "n", "]c", { buffer = bufnr })
	pcall(vim.keymap.del, "n", "[c", { buffer = bufnr })
	pcall(vim.keymap.del, "n", "cr", { buffer = bufnr })
	active_diffs[bufnr] = nil
end

local function flash_line(bufnr, line)
	pcall(vim.api.nvim_buf_set_extmark, bufnr, flash_ns, line - 1, 0, {
		line_hl_group = "IncSearch", priority = 100,
	})
	vim.defer_fn(function()
		pcall(vim.api.nvim_buf_clear_namespace, bufnr, flash_ns, 0, -1)
	end, 300)
end

--- Compute diff stats for a file (for sidebar display)
---@return number additions, number deletions
function M.file_stats(filepath, bufnr)
	local hunks = compute_hunks(filepath, bufnr or 0)
	if not hunks then return 0, 0 end
	local add, del = 0, 0
	for _, h in ipairs(hunks) do
		add = add + h[4]
		del = del + h[2]
	end
	return add, del
end

--- Count hunks for a file
function M.hunk_count(filepath, bufnr)
	local hunks = compute_hunks(filepath, bufnr or 0)
	return hunks and #hunks or 0
end

--- Apply lightweight sign-column-only indicators
function M.apply_signs(bufnr, filepath)
	highlights.setup()

	local hunks = compute_hunks(filepath, bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr, sign_ns, 0, -1)
	if not hunks or #hunks == 0 then return end

	for _, hunk in ipairs(hunks) do
		local old_count, new_start, new_count = hunk[2], hunk[3], hunk[4]
		if old_count == 0 and new_count > 0 then
			pcall(vim.api.nvim_buf_set_extmark, bufnr, sign_ns, new_start - 1, 0, {
				end_row = new_start + new_count - 2,
				sign_text = "┃", sign_hl_group = "ClaudeDiffAddSign",
				number_hl_group = "ClaudeDiffAddSign", priority = 15,
			})
		elseif new_count == 0 then
			pcall(vim.api.nvim_buf_set_extmark, bufnr, sign_ns, math.max(0, new_start - 1), 0, {
				sign_text = "▁", sign_hl_group = "ClaudeDiffDeleteSign", priority = 15,
			})
		else
			pcall(vim.api.nvim_buf_set_extmark, bufnr, sign_ns, new_start - 1, 0, {
				end_row = new_start + new_count - 2,
				sign_text = "┃", sign_hl_group = "ClaudeDiffChangeSign",
				number_hl_group = "ClaudeDiffChangeSign", priority = 15,
			})
		end
	end
end

--- Show full inline diff. Toggles off if already shown.
function M.show(filepath)
	filepath = filepath or vim.api.nvim_buf_get_name(0)
	if filepath == "" then return end

	highlights.setup()

	local bufnr = vim.api.nvim_get_current_buf()
	if vim.api.nvim_buf_get_name(bufnr) ~= filepath then
		vim.cmd("edit " .. vim.fn.fnameescape(filepath))
		bufnr = vim.api.nvim_get_current_buf()
	end

	if active_diffs[bufnr] then
		clear(bufnr)
		M.apply_signs(bufnr, filepath)
		return
	end

	local before_lines = get_before_lines(filepath)
	if not before_lines then
		vim.notify("No snapshot or git history for this file", vim.log.levels.WARN)
		return
	end

	local hunks = compute_hunks(filepath, bufnr)
	clear(bufnr)

	if not hunks or #hunks == 0 then
		vim.notify("No changes", vim.log.levels.INFO)
		return
	end

	local hunk_lines = {}
	local full_hunks = {}
	local first_change = nil

	for _, hunk in ipairs(hunks) do
		local old_start, old_count, new_start, new_count = hunk[1], hunk[2], hunk[3], hunk[4]
		hunk_lines[#hunk_lines + 1] = math.max(1, new_start)
		full_hunks[#full_hunks + 1] = {
			old_start = old_start, old_count = old_count,
			new_start = new_start, new_count = new_count,
		}

		if old_count == 0 and new_count > 0 then
			if not first_change then first_change = new_start end
			for line = new_start, new_start + new_count - 1 do
				pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line - 1, 0, {
					line_hl_group = "ClaudeDiffAdd",
					sign_text = "┃", sign_hl_group = "ClaudeDiffAddSign",
				})
			end

		elseif new_count == 0 then
			if not first_change then first_change = math.max(1, new_start) end
			local virt_lines = {}
			for i = old_start, old_start + old_count - 1 do
				if before_lines[i] then
					virt_lines[#virt_lines + 1] = {
						{ "  - ", "ClaudeDiffDeleteNr" },
						{ before_lines[i], "ClaudeDiffDelete" },
					}
				end
			end
			if #virt_lines > 0 then
				pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, math.max(0, new_start - 1), 0, {
					virt_lines = virt_lines,
					virt_lines_above = (new_start > 0),
					sign_text = "▁", sign_hl_group = "ClaudeDiffDeleteSign",
				})
			end

		else
			if not first_change then first_change = new_start end
			local virt_lines = {}
			for i = old_start, old_start + old_count - 1 do
				if before_lines[i] then
					virt_lines[#virt_lines + 1] = {
						{ "  ~ ", "ClaudeDiffDeleteNr" },
						{ before_lines[i], "ClaudeDiffDelete" },
					}
				end
			end
			if #virt_lines > 0 then
				pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, new_start - 1, 0, {
					virt_lines = virt_lines, virt_lines_above = true,
				})
			end
			for line = new_start, new_start + new_count - 1 do
				pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line - 1, 0, {
					line_hl_group = "ClaudeDiffChange",
					sign_text = "┃", sign_hl_group = "ClaudeDiffChangeSign",
				})
			end
		end
	end

	active_diffs[bufnr] = { hunks = full_hunks, hunk_lines = hunk_lines, filepath = filepath }

	-- ]c / [c hunk navigation with flash
	vim.keymap.set("n", "]c", function()
		local row = vim.api.nvim_win_get_cursor(0)[1]
		for _, h in ipairs(hunk_lines) do
			if h > row then
				vim.api.nvim_win_set_cursor(0, { h, 0 })
				vim.cmd("normal! zz")
				flash_line(bufnr, h)
				return
			end
		end
		vim.notify("No next hunk", vim.log.levels.INFO)
	end, { buffer = bufnr, silent = true, desc = "Next Claude hunk" })

	vim.keymap.set("n", "[c", function()
		local row = vim.api.nvim_win_get_cursor(0)[1]
		for i = #hunk_lines, 1, -1 do
			if hunk_lines[i] < row then
				vim.api.nvim_win_set_cursor(0, { hunk_lines[i], 0 })
				vim.cmd("normal! zz")
				flash_line(bufnr, hunk_lines[i])
				return
			end
		end
		vim.notify("No previous hunk", vim.log.levels.INFO)
	end, { buffer = bufnr, silent = true, desc = "Previous Claude hunk" })

	-- cr: revert hunk under cursor to pre-Claude state
	vim.keymap.set("n", "cr", function()
		local row = vim.api.nvim_win_get_cursor(0)[1]
		local state = active_diffs[bufnr]
		if not state then return end

		local bl = get_before_lines(state.filepath)
		if not bl then return end

		for _, h in ipairs(state.hunks) do
			local in_hunk
			if h.new_count == 0 then
				in_hunk = (row == math.max(1, h.new_start))
			else
				in_hunk = (row >= h.new_start and row < h.new_start + h.new_count)
			end

			if in_hunk then
				local old_lines = {}
				for i = h.old_start, h.old_start + h.old_count - 1 do
					if bl[i] then old_lines[#old_lines + 1] = bl[i] end
				end
				vim.api.nvim_buf_set_lines(bufnr, h.new_start - 1, h.new_start - 1 + h.new_count, false, old_lines)
				clear(bufnr)
				M.show(state.filepath)
				vim.notify("Hunk reverted", vim.log.levels.INFO)
				return
			end
		end
		vim.notify("No hunk under cursor", vim.log.levels.INFO)
	end, { buffer = bufnr, silent = true, desc = "Revert Claude hunk" })

	-- Always jump to first change
	if first_change then
		pcall(vim.api.nvim_win_set_cursor, 0, { first_change, 0 })
		vim.cmd("normal! zz")
		flash_line(bufnr, first_change)
	end

	vim.notify(#hunks .. " hunk(s)  ]c/[c nav  cr revert", vim.log.levels.INFO)
end

M.clear = clear

return M
