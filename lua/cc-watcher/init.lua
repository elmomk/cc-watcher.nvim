-- cc-watcher.nvim — See what Claude Code is changing in real time

local M = {}

local defaults = {
	sidebar_width = 1.0,
	keys = {
		toggle_sidebar = "<leader>cs",
		toggle_diff = "<leader>cd",
		snacks_files = "<leader>ct",
		snacks_hunks = "<leader>ch",
		trouble = "<leader>cx",
		diffview = "<leader>cv",
		flash = "<leader>cf",
	},
	integrations = {
		snacks = false,
		fzf_lua = false,
		trouble = false,
		diffview = false,
		conform = false,
		neotest = false,
		gitsigns = false,
		neotree = false,
		edgy = false,
		fidget = false,
		overseer = false,
		flash = false,
		mini_diff = false,
		notifier = false,
	},
}

M.config = vim.deepcopy(defaults)

local _setup_done = false

--- Internal: ensure setup() has been called at least once (with defaults).
--- Used by command stubs in plugin/cc-watcher.lua so that lazy-loaded
--- commands work even if the user never called setup() explicitly.
function M._ensure_setup()
	if not _setup_done then
		M.setup()
	end
end

--- Primary configuration entry point. Idempotent — safe to call multiple times.
--- On repeated calls the config is updated but watchers/keymaps are not re-registered.
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", defaults, opts or {})

	if _setup_done then
		return
	end
	_setup_done = true

	local watcher = require("cc-watcher.watcher")
	local sidebar = require("cc-watcher.sidebar")
	local session = require("cc-watcher.session")
	local diff = require("cc-watcher.diff")

	watcher.setup()
	sidebar.setup()
	diff.setup()
	session.watch_jsonl()

	-- Keymaps
	local keys = M.config.keys
	if keys.toggle_sidebar then
		vim.keymap.set("n", keys.toggle_sidebar, function()
			require("cc-watcher.sidebar").toggle()
		end, {
			silent = true, desc = "Claude - toggle sidebar",
		})
	end
	if keys.toggle_diff then
		vim.keymap.set("n", keys.toggle_diff, function()
			require("cc-watcher.diff").show()
		end, {
			silent = true, desc = "Claude - toggle inline diff",
		})
	end
	if keys.snacks_files then
		vim.keymap.set("n", keys.snacks_files, "<cmd>ClaudeSnacks<cr>", {
			silent = true, desc = "Claude - changed files",
		})
	end
	if keys.snacks_hunks then
		vim.keymap.set("n", keys.snacks_hunks, "<cmd>ClaudeSnacks hunks<cr>", {
			silent = true, desc = "Claude - hunks",
		})
	end
	if keys.trouble then
		vim.keymap.set("n", keys.trouble, "<cmd>ClaudeTrouble<cr>", {
			silent = true, desc = "Claude - trouble",
		})
	end
	if keys.diffview then
		vim.keymap.set("n", keys.diffview, "<cmd>ClaudeDiffview<cr>", {
			silent = true, desc = "Claude - diffview",
		})
	end
	if keys.flash then
		vim.keymap.set("n", keys.flash, "<cmd>ClaudeFlash<cr>", {
			silent = true, desc = "Claude - flash jump",
		})
	end

	-- Hook-based integrations (opt-in, lazy-loaded)
	local int = M.config.integrations
	local int_map = {
		conform   = "cc-watcher.integrations.conform",
		neotest   = "cc-watcher.integrations.neotest",
		gitsigns  = "cc-watcher.integrations.gitsigns",
		neotree   = "cc-watcher.integrations.neotree",
		edgy      = "cc-watcher.integrations.edgy",
		fidget    = "cc-watcher.integrations.fidget",
		overseer  = "cc-watcher.integrations.overseer",
		flash     = "cc-watcher.integrations.flash",
		mini_diff = "cc-watcher.integrations.mini_diff",
		notifier  = "cc-watcher.integrations.notifier",
	}
	for key, mod_name in pairs(int_map) do
		if int[key] then
			local iok, imod = pcall(require, mod_name)
			if iok and imod.setup then imod.setup() end
		end
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

--- Lazy.nvim spec helpers — spread into your plugin spec:
---   { "user/cc-watcher.nvim", opts = { ... }, ... require("cc-watcher").lazy }
M.lazy = {
	cmd = {
		"ClaudeSidebar", "ClaudeDiff",
		"ClaudeSnacks", "ClaudeFzf", "ClaudeTrouble", "ClaudeDiffview", "ClaudeFlash",
	},
	keys = {
		{ "<leader>cs", function() require("cc-watcher")._ensure_setup(); require("cc-watcher.sidebar").toggle() end, desc = "Claude - toggle sidebar" },
		{ "<leader>cd", function() require("cc-watcher")._ensure_setup(); require("cc-watcher.diff").show() end, desc = "Claude - toggle inline diff" },
		{ "<leader>ct", "<cmd>ClaudeSnacks<cr>", desc = "Claude - changed files" },
		{ "<leader>ch", "<cmd>ClaudeSnacks hunks<cr>", desc = "Claude - hunks" },
		{ "<leader>cx", "<cmd>ClaudeTrouble<cr>", desc = "Claude - trouble" },
		{ "<leader>cv", "<cmd>ClaudeDiffview<cr>", desc = "Claude - diffview" },
		{ "<leader>cf", "<cmd>ClaudeFlash<cr>", desc = "Claude - flash jump" },
	},
	event = { "BufReadPost", "BufNewFile" },
}

return M
