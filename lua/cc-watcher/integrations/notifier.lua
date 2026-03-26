-- Rich notifications via snacks.nvim notifier
local M = {}
local _done = false

function M.setup()
	if _done then return end
	_done = true

	local ok = pcall(require, "snacks")
	if not ok then return end

	local Snacks = require("snacks")
	local pending = {}
	local timer = vim.uv.new_timer()

	require("cc-watcher.watcher").on_change(function(_, relpath)
		pending[#pending + 1] = relpath
		timer:stop()
		timer:start(800, 0, vim.schedule_wrap(function()
			if #pending == 0 then return end

			local msg
			if #pending == 1 then
				msg = pending[1]
			elseif #pending <= 5 then
				msg = table.concat(pending, "\n")
			else
				msg = pending[1] .. "\n" .. pending[2] .. "\n... and " .. (#pending - 2) .. " more"
			end

			Snacks.notify(msg, {
				title = "󰚩 Claude Code",
				level = "info",
				timeout = 3000,
			})
			pending = {}
		end))
	end)
end

return M
