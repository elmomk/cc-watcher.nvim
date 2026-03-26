-- Use mini.diff with Claude snapshots as reference source
local M = {}
local _done = false

function M.setup()
	if _done then return end
	_done = true

	local ok = pcall(require, "mini.diff")
	if not ok then return end

	-- Register a custom source for mini.diff that uses Claude's baseline
	-- Users can activate it with: MiniDiff.enable(bufnr, { source = require("cc-watcher.integrations.mini_diff").source })
	M.source = {
		name = "claude",
		attach = function(bufnr)
			local filepath = vim.api.nvim_buf_get_name(bufnr)
			if filepath == "" then return false end
			local util = require("cc-watcher.util")
			local old_text = util.get_old_text(filepath)
			if old_text == "" then return false end

			-- Set reference text
			local ref_lines = vim.split(old_text, "\n", { plain = true })
			pcall(require("mini.diff").set_ref_text, bufnr, ref_lines)

			-- Refresh when file changes
			require("cc-watcher.watcher").on_change(function(fp)
				if fp ~= filepath then return end
				vim.schedule(function()
					if not vim.api.nvim_buf_is_valid(bufnr) then return end
					local new_old = util.get_old_text(filepath)
					if new_old ~= "" then
						local lines = vim.split(new_old, "\n", { plain = true })
						pcall(require("mini.diff").set_ref_text, bufnr, lines)
					end
				end)
			end)
			return true
		end,
		detach = function(bufnr) end,
	}

	-- Auto-attach to buffers that Claude has changed
	require("cc-watcher.watcher").on_change(function(filepath)
		local bufnr = vim.fn.bufnr(filepath)
		if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then return end
		vim.schedule(function()
			if vim.api.nvim_buf_is_valid(bufnr) then
				pcall(require("mini.diff").enable, bufnr, { source = M.source })
			end
		end)
	end)
end

return M
