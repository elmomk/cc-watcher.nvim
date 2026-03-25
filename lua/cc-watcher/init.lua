-- claude-code.nvim — See what Claude Code is changing in real time
--
-- Shows a sidebar of files Claude edited, inline diffs with colored
-- highlights, and sign column indicators for changed lines.
--
-- Reads Claude Code's session JSONL to know exactly which files were
-- touched. Uses libuv fs_event watchers for instant change detection.
-- Diffs against pre-change snapshots, not git HEAD.

local M = {}

local defaults = {
	-- Sidebar width
	sidebar_width = 36,
	-- Keymaps (set to false to disable)
	keys = {
		toggle_sidebar = "<leader>cs",
		toggle_diff = "<leader>cd",
	},
	-- Auto-apply sign column indicators when files change
	auto_signs = true,
}

M.config = vim.deepcopy(defaults)

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", defaults, opts or {})

	local watcher = require("cc-watcher.watcher")
	local sidebar = require("cc-watcher.sidebar")
	local diff = require("cc-watcher.diff")

	watcher.setup()
	sidebar.setup()

	-- Commands
	vim.api.nvim_create_user_command("ClaudeSidebar", sidebar.toggle, {
		desc = "Toggle Claude Code changed files sidebar",
	})
	vim.api.nvim_create_user_command("ClaudeDiff", function() diff.show() end, {
		desc = "Toggle inline diff for current file",
	})

	-- Keymaps
	local keys = M.config.keys
	if keys.toggle_sidebar then
		vim.keymap.set("n", keys.toggle_sidebar, sidebar.toggle, {
			silent = true, desc = "Claude - toggle sidebar",
		})
	end
	if keys.toggle_diff then
		vim.keymap.set("n", keys.toggle_diff, function() diff.show() end, {
			silent = true, desc = "Claude - toggle inline diff",
		})
	end
end

return M
