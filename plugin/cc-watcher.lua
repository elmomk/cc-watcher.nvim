-- cc-watcher.nvim — auto-loaded entry point
-- Registers lightweight command stubs so lazy.nvim can load on cmd = { ... }

if vim.g.loaded_cc_watcher then return end
vim.g.loaded_cc_watcher = true

local function ensure()
	require("cc-watcher")._ensure_setup()
end

vim.api.nvim_create_user_command("ClaudeSidebar", function()
	ensure()
	require("cc-watcher.sidebar").toggle()
end, {
	desc = "Toggle Claude Code changed files sidebar",
})

vim.api.nvim_create_user_command("ClaudeDiff", function()
	ensure()
	require("cc-watcher.diff").show()
end, {
	desc = "Toggle inline diff for current file",
})

vim.api.nvim_create_user_command("ClaudeSnacks", function(args)
	ensure()
	local cfg = require("cc-watcher").config
	if not cfg.integrations.snacks then
		vim.notify("cc-watcher: snacks integration is disabled. Enable it with integrations.snacks = true", vim.log.levels.WARN)
		return
	end
	local ok, snacks_mod = pcall(require, "cc-watcher.snacks")
	if not ok then
		vim.notify("cc-watcher: snacks.nvim not found", vim.log.levels.ERROR)
		return
	end
	local sub = args.fargs[1]
	if sub == "hunks" then snacks_mod.hunks()
	else snacks_mod.changed_files() end
end, {
	nargs = "?",
	complete = function() return { "changed_files", "hunks" } end,
	desc = "Snacks: Claude Code changes",
})

vim.api.nvim_create_user_command("ClaudeFzf", function(args)
	ensure()
	local cfg = require("cc-watcher").config
	if not cfg.integrations.fzf_lua then
		vim.notify("cc-watcher: fzf_lua integration is disabled. Enable it with integrations.fzf_lua = true", vim.log.levels.WARN)
		return
	end
	local ok, fzf = pcall(require, "cc-watcher.fzf")
	if not ok then
		vim.notify("cc-watcher: fzf-lua not found", vim.log.levels.ERROR)
		return
	end
	local sub = args.fargs[1]
	if sub == "hunks" then fzf.hunks()
	else fzf.changed_files() end
end, {
	nargs = "?",
	complete = function() return { "changed_files", "hunks" } end,
	desc = "fzf-lua: Claude Code changes",
})

vim.api.nvim_create_user_command("ClaudeTrouble", function()
	ensure()
	local cfg = require("cc-watcher").config
	if not cfg.integrations.trouble then
		vim.notify("cc-watcher: trouble integration is disabled. Enable it with integrations.trouble = true", vim.log.levels.WARN)
		return
	end
	local ok, trouble = pcall(require, "trouble")
	if not ok then
		vim.notify("cc-watcher: trouble.nvim not found", vim.log.levels.ERROR)
		return
	end
	trouble.open({ mode = "claude" })
end, {
	desc = "Trouble: Claude Code changes",
})

vim.api.nvim_create_user_command("ClaudeFlash", function()
	ensure()
	local cfg = require("cc-watcher").config
	if not cfg.integrations.flash then
		vim.notify("cc-watcher: flash integration is disabled. Enable it with integrations.flash = true", vim.log.levels.WARN)
		return
	end
	local ok, flash_mod = pcall(require, "cc-watcher.integrations.flash")
	if not ok then
		vim.notify("cc-watcher: flash.nvim not found", vim.log.levels.ERROR)
		return
	end
	flash_mod.jump()
end, {
	desc = "Flash: jump to Claude hunk",
})

vim.api.nvim_create_user_command("ClaudeSession", function()
	ensure()
	require("cc-watcher.session").pick(function()
		local sidebar_ok, sidebar = pcall(require, "cc-watcher.sidebar")
		if sidebar_ok then sidebar.render() end
	end)
end, {
	desc = "Pick which Claude Code session to watch",
})

vim.api.nvim_create_user_command("ClaudeMcp", function(args)
	ensure()
	local cfg = require("cc-watcher").config
	if not cfg.mcp.enabled then
		vim.notify("cc-watcher: mcp is disabled. Enable it with mcp = { enabled = true }", vim.log.levels.WARN)
		return
	end
	local mcp = require("cc-watcher.mcp")
	local sub = args.fargs[1]
	if sub == "start" then
		local ok, err = mcp.start()
		if not ok then
			vim.notify("cc-watcher/mcp: start failed: " .. (err or "unknown"), vim.log.levels.ERROR)
		end
	elseif sub == "stop" then
		mcp.stop()
		vim.notify("cc-watcher/mcp: stopped", vim.log.levels.INFO)
	elseif sub == "status" then
		local s = mcp.status()
		local lines = {
			"MCP Bridge: " .. (s.running and "running" or "stopped"),
		}
		if s.running then
			lines[#lines + 1] = "  Port: " .. (s.port or "?")
			lines[#lines + 1] = "  Connections: " .. s.active_connections .. "/" .. s.connections
			lines[#lines + 1] = "  Pending diffs: " .. s.pending_diffs
			lines[#lines + 1] = "  Lock file: " .. (s.lock_file or "none")
		end
		vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
	else
		vim.notify("Usage: ClaudeMcp {start|stop|status}", vim.log.levels.INFO)
	end
end, {
	nargs = "?",
	complete = function() return { "start", "stop", "status" } end,
	desc = "MCP WebSocket bridge for Claude Code",
})
vim.api.nvim_create_user_command("ClaudeDiffview", function(args)
	ensure()
	local cfg = require("cc-watcher").config
	if not cfg.integrations.diffview then
		vim.notify("cc-watcher: diffview integration is disabled. Enable it with integrations.diffview = true", vim.log.levels.WARN)
		return
	end
	local ok, dv = pcall(require, "cc-watcher.diffview")
	if not ok then
		vim.notify("cc-watcher: diffview module failed to load", vim.log.levels.ERROR)
		return
	end
	local filepath = args.fargs[1]
	if filepath then
		dv.open_file(vim.fn.fnamemodify(filepath, ":p"))
	else
		dv.open()
	end
end, {
	nargs = "?",
	complete = "file",
	desc = "Diffview: Claude Code changes",
})
