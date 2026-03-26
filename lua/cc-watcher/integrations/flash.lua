-- Enhanced hunk navigation with flash.nvim labels
local M = {}
local _done = false

function M.setup()
	if _done then return end
	_done = true
	-- flash is loaded on-demand, no eager init needed
end

--- Jump to any Claude hunk using flash labels
function M.jump()
	local ok, flash = pcall(require, "flash")
	if not ok then
		vim.notify("flash.nvim is required for this feature", vim.log.levels.ERROR)
		return
	end

	local util = require("cc-watcher.util")
	local watcher = require("cc-watcher.watcher")
	local bufnr = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	if filepath == "" then return end

	-- Get hunks for current file
	local old_text = util.get_old_text(filepath)
	local new_text = util.read_file(filepath) or ""
	local hunks = util.compute_hunks(old_text, new_text)
	if not hunks or #hunks == 0 then
		vim.notify("No hunks in current file", vim.log.levels.INFO)
		return
	end

	-- Build flash targets from hunk start lines
	local pattern = table.concat(
		vim.tbl_map(function(h)
			return "\\%" .. math.max(1, h[3]) .. "l"
		end, hunks),
		"\\|"
	)

	flash.jump({
		search = { mode = "search" },
		pattern = pattern,
		label = { after = false, before = true },
		highlight = { backdrop = true },
	})
end

return M
