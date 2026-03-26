-- Auto-format files after Claude edits them (requires conform.nvim)
local M = {}
local _done = false

function M.setup()
	if _done then return end
	_done = true

	local ok, conform = pcall(require, "conform")
	if not ok then return end

	require("cc-watcher.watcher").on_change(function(filepath)
		local bufnr = vim.fn.bufnr(filepath)
		if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then return end
		vim.schedule(function()
			if vim.api.nvim_buf_is_valid(bufnr) then
				conform.format({ bufnr = bufnr, async = true, quiet = true })
			end
		end)
	end)
end

return M
