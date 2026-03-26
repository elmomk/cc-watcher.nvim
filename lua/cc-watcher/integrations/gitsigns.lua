-- Coordinate with gitsigns.nvim: refresh signs when Claude edits files
local M = {}
local _done = false

function M.setup()
	if _done then return end
	_done = true

	local ok = pcall(require, "gitsigns")
	if not ok then return end

	require("cc-watcher.watcher").on_change(function(filepath)
		local bufnr = vim.fn.bufnr(filepath)
		if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then return end
		vim.schedule(function()
			if not vim.api.nvim_buf_is_valid(bufnr) then return end
			-- Refresh gitsigns for this buffer so it picks up the new content
			pcall(require("gitsigns").refresh)
		end)
	end)
end

return M
