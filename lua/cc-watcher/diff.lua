-- diff.lua — Inline diff highlighting for Claude Code changes
-- Toggle on/off. Sign column indicators. Hunk navigation.

local M = {}

local snapshots = require("cc-watcher.snapshots")
local highlights = require("cc-watcher.highlights")

local ns = vim.api.nvim_create_namespace("claude_diff")
local sign_ns = vim.api.nvim_create_namespace("claude_diff_signs")

local active_diffs = {} -- bufnr -> { hunks = {{new_start, new_count}...} }

local function relpath(filepath)
	local cwd = vim.fn.getcwd()
	if filepath:sub(1, #cwd) == cwd then
		return filepath:sub(#cwd + 2)
	end
	return filepath
end

---@param filepath string
---@return string[]|nil
local function get_before_lines(filepath)
	local snap = snapshots.get(filepath)
	if snap then return snap.lines end

	local rel = relpath(filepath)
	local lines = vim.fn.systemlist("git show HEAD:" .. vim.fn.shellescape(rel) .. " 2>/dev/null")
	if vim.v.shell_error == 0 and #lines > 0 then return lines end
	return nil
end

---@param bufnr number
local function clear(bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	vim.api.nvim_buf_clear_namespace(bufnr, sign_ns, 0, -1)
	-- Remove hunk nav keymaps
	pcall(vim.keymap.del, "n", "]c", { buffer = bufnr })
	pcall(vim.keymap.del, "n", "[c", { buffer = bufnr })
	active_diffs[bufnr] = nil
end

--- Apply sign-column-only indicators (lightweight, no virtual text)
function M.apply_signs(bufnr, filepath)
	highlights.setup()

	local before_lines = get_before_lines(filepath)
	if not before_lines then return end

	local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local old_text = table.concat(before_lines, "\n") .. "\n"
	local new_text = table.concat(current_lines, "\n") .. "\n"

	local hunks = vim.diff(old_text, new_text, {
		result_type = "indices",
		algorithm = "histogram",
	})

	vim.api.nvim_buf_clear_namespace(bufnr, sign_ns, 0, -1)
	if not hunks or #hunks == 0 then return end

	for _, hunk in ipairs(hunks) do
		local old_count, new_start, new_count = hunk[2], hunk[3], hunk[4]
		if old_count == 0 then
			for line = new_start, new_start + new_count - 1 do
				pcall(vim.api.nvim_buf_set_extmark, bufnr, sign_ns, line - 1, 0, {
					sign_text = "┃", sign_hl_group = "ClaudeDiffAddSign", priority = 20,
				})
			end
		elseif new_count == 0 then
			pcall(vim.api.nvim_buf_set_extmark, bufnr, sign_ns, math.max(0, new_start - 1), 0, {
				sign_text = "▁", sign_hl_group = "ClaudeDiffDeleteSign", priority = 20,
			})
		else
			for line = new_start, new_start + new_count - 1 do
				pcall(vim.api.nvim_buf_set_extmark, bufnr, sign_ns, line - 1, 0, {
					sign_text = "┃", sign_hl_group = "ClaudeDiffChangeSign", priority = 20,
				})
			end
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

	-- Toggle off
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

	local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local old_text = table.concat(before_lines, "\n") .. "\n"
	local new_text = table.concat(current_lines, "\n") .. "\n"

	local hunks = vim.diff(old_text, new_text, {
		result_type = "indices",
		algorithm = "histogram",
	})

	clear(bufnr)

	if not hunks or #hunks == 0 then
		vim.notify("No changes", vim.log.levels.INFO)
		return
	end

	-- Collect hunk positions for navigation
	local hunk_lines = {}
	local first_change = nil

	for _, hunk in ipairs(hunks) do
		local old_start, old_count, new_start, new_count = hunk[1], hunk[2], hunk[3], hunk[4]
		table.insert(hunk_lines, math.max(1, new_start))

		if old_count == 0 then
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
					table.insert(virt_lines, {
						{ "  - ", "ClaudeDiffDeleteNr" },
						{ before_lines[i], "ClaudeDiffDelete" },
					})
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
					table.insert(virt_lines, {
						{ "  ~ ", "ClaudeDiffDeleteNr" },
						{ before_lines[i], "ClaudeDiffDelete" },
					})
				end
			end
			if #virt_lines > 0 then
				pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, new_start - 1, 0, {
					virt_lines = virt_lines,
					virt_lines_above = true,
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

	active_diffs[bufnr] = { hunks = hunk_lines }

	-- Hunk navigation: ]c next, [c previous
	vim.keymap.set("n", "]c", function()
		local row = vim.api.nvim_win_get_cursor(0)[1]
		for _, h in ipairs(hunk_lines) do
			if h > row then
				vim.api.nvim_win_set_cursor(0, { h, 0 })
				vim.cmd("normal! zz")
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
				return
			end
		end
		vim.notify("No previous hunk", vim.log.levels.INFO)
	end, { buffer = bufnr, silent = true, desc = "Previous Claude hunk" })

	-- Jump to first change only if not visible
	if first_change then
		local win_top = vim.fn.line("w0")
		local win_bot = vim.fn.line("w$")
		if first_change < win_top or first_change > win_bot then
			pcall(vim.api.nvim_win_set_cursor, 0, { first_change, 0 })
			vim.cmd("normal! zz")
		end
	end
end

M.clear = clear

return M
