-- Trigger overseer tasks when Claude edits files (requires overseer.nvim)
-- Users configure tasks via overseer templates; this module provides
-- a "claude_file_changed" trigger component.
local M = {}
local _done = false

function M.setup()
	if _done then return end
	_done = true

	local ok = pcall(require, "overseer")
	if not ok then return end

	require("cc-watcher.watcher").on_change(function(filepath, relpath)
		vim.schedule(function()
			-- Fire a user event that overseer templates can listen to
			vim.api.nvim_exec_autocmds("User", {
				pattern = "ClaudeFileChanged",
				data = { filepath = filepath, relpath = relpath },
			})
		end)
	end)
end

--- Convenience: run a named overseer task
---@param task_name string
function M.run_on_change(task_name)
	local overseer = require("overseer")
	require("cc-watcher.watcher").on_change(function()
		vim.schedule(function()
			overseer.run_template({ name = task_name })
		end)
	end)
end

return M
