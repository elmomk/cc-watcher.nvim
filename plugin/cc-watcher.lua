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
