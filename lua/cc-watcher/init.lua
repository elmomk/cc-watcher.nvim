-- cc-watcher.nvim — See what Claude Code is changing in real time

local M = {}

local defaults = {
	sidebar_width = 36,
	keys = {
		toggle_sidebar = "<leader>cs",
		toggle_diff = "<leader>cd",
	},
}

M.config = vim.deepcopy(defaults)

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", defaults, opts or {})

	local watcher = require("cc-watcher.watcher")
	local sidebar = require("cc-watcher.sidebar")
	local diff = require("cc-watcher.diff")
	local session = require("cc-watcher.session")

	watcher.setup()
	sidebar.setup()
	session.watch_jsonl()

	vim.api.nvim_create_user_command("ClaudeSidebar", sidebar.toggle, {
		desc = "Toggle Claude Code changed files sidebar",
	})
	vim.api.nvim_create_user_command("ClaudeDiff", function() diff.show() end, {
		desc = "Toggle inline diff for current file",
	})

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

	-- which-key integration (if available)
	local wk_ok, wk = pcall(require, "which-key")
	if wk_ok and wk.add then
		pcall(wk.add, {
			{ "<leader>c", group = "Claude Code" },
		})
	end
end

--- Statusline component: returns "" or "󰚩 N" for lualine/heirline
function M.statusline()
	local ok, watcher = pcall(require, "cc-watcher.watcher")
	if not ok then return "" end
	local n = vim.tbl_count(watcher.get_changed_files())
	if n == 0 then return "" end
	return "󰚩 " .. n
end

return M
