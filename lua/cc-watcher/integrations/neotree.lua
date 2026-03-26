-- Mark Claude-changed files in neo-tree (requires neo-tree.nvim)
local M = {}
local _done = false

function M.setup()
	if _done then return end
	_done = true

	local ok, events = pcall(require, "neo-tree.events")
	if not ok then return end

	-- Refresh neo-tree when Claude changes files
	require("cc-watcher.watcher").on_change(function()
		vim.schedule(function()
			-- Fire neo-tree refresh event
			pcall(events.fire_event, events.GIT_EVENT)
		end)
	end)

	-- Register a custom component for neo-tree that shows Claude indicators
	local ok2 = pcall(require, "neo-tree.sources.common.components")
	if ok2 then
		-- Add claude_indicator to available components
		local watcher = require("cc-watcher.watcher")

		-- Users can add this to their neo-tree config:
		-- components = { claude_indicator = function(config, node) ... end }
		M.component = function(config, node, state)
			local filepath = node:get_id()
			if watcher.get_changed_files()[filepath] then
				return {
					text = " 󰚩",
					highlight = "ClaudeLive",
				}
			end
			return {}
		end
	end
end

--- Get list of changed file paths (for external use)
function M.changed_paths()
	local watcher = require("cc-watcher.watcher")
	local paths = {}
	for fp in pairs(watcher.get_changed_files()) do
		paths[#paths + 1] = fp
	end
	return paths
end

return M
