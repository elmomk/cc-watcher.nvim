-- Show Claude activity spinner via fidget.nvim
local M = {}
local _done = false

function M.setup()
	if _done then return end
	_done = true

	local ok = pcall(require, "fidget")
	if not ok then return end

	local fidget = require("fidget")
	local session = require("cc-watcher.session")
	local handle = nil

	-- Show spinner when JSONL changes (= Claude is actively working)
	session.on_jsonl_change(function()
		vim.schedule(function()
			if handle then
				-- Update existing notification
				pcall(function()
					handle.message = "editing files..."
				end)
			else
				-- Create new progress notification
				handle = fidget.notification.notify("editing files...", vim.log.levels.INFO, {
					key = "claude_activity",
					group = "Claude Code",
					annote = "󰚩",
					ttl = 5,
				})
			end

			-- Auto-clear after 3 seconds of inactivity
			vim.defer_fn(function()
				if handle then
					pcall(function()
						handle.message = "done"
						handle = nil
					end)
				end
			end, 3000)
		end)
	end)
end

return M
