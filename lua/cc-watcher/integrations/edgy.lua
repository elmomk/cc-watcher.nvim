-- Dock Claude sidebar with edgy.nvim
-- Users add this to their edgy config:
--   require("cc-watcher.integrations.edgy").edgy_config
local M = {}
local _done = false

-- Pre-built edgy panel config for the Claude sidebar
M.panel = {
	ft = "claude-sidebar",
	title = "Claude Code",
	size = { width = 36 },
	pinned = true,
	open = "ClaudeSidebar",
}

function M.setup()
	if _done then return end
	_done = true

	local ok, edgy = pcall(require, "edgy")
	if not ok then return end

	-- If edgy is loaded, register our sidebar filetype
	-- Users should add M.panel to their edgy left/right config
	-- This setup just ensures the filetype is recognized
	vim.api.nvim_create_autocmd("FileType", {
		pattern = "claude-sidebar",
		callback = function()
			vim.wo.winfixwidth = true
		end,
	})
end

return M
