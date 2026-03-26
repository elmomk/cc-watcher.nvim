local T = MiniTest.new_set()

T["init"] = MiniTest.new_set()

T["init"]["_ensure_setup() initializes on first call"] = function()
	-- Fresh require to get the module
	local cc = require("cc-watcher")

	-- Force a fresh state by calling setup explicitly
	cc.setup({ sidebar_width = 42 })
	MiniTest.expect.equality(cc.config.sidebar_width, 42)
end

T["init"]["setup() is idempotent — second call updates config but does not error"] = function()
	local cc = require("cc-watcher")

	-- First call
	cc.setup({ sidebar_width = 30 })
	MiniTest.expect.equality(cc.config.sidebar_width, 30)

	-- Second call — should update config without error
	cc.setup({ sidebar_width = 50 })
	MiniTest.expect.equality(cc.config.sidebar_width, 50)
end

T["init"]["setup() merges opts with defaults"] = function()
	local cc = require("cc-watcher")

	cc.setup({ sidebar_width = 40 })

	-- Explicitly set value
	MiniTest.expect.equality(cc.config.sidebar_width, 40)

	-- Defaults preserved for unset values
	MiniTest.expect.equality(cc.config.keys.toggle_sidebar, "<leader>cs")
	MiniTest.expect.equality(cc.config.keys.toggle_diff, "<leader>cd")
	MiniTest.expect.equality(cc.config.integrations.telescope, false)
	MiniTest.expect.equality(cc.config.integrations.fzf_lua, false)
	MiniTest.expect.equality(cc.config.integrations.trouble, false)
	MiniTest.expect.equality(cc.config.integrations.diffview, false)
end

T["init"]["setup() deep merges nested tables"] = function()
	local cc = require("cc-watcher")

	cc.setup({
		keys = { toggle_sidebar = "<leader>cc" },
		integrations = { telescope = true },
	})

	-- Overridden
	MiniTest.expect.equality(cc.config.keys.toggle_sidebar, "<leader>cc")
	MiniTest.expect.equality(cc.config.integrations.telescope, true)

	-- Defaults preserved for siblings
	MiniTest.expect.equality(cc.config.keys.toggle_diff, "<leader>cd")
	MiniTest.expect.equality(cc.config.integrations.fzf_lua, false)
end

T["init"]["setup() with no args uses all defaults"] = function()
	local cc = require("cc-watcher")

	cc.setup()

	MiniTest.expect.equality(cc.config.sidebar_width, 36)
	MiniTest.expect.equality(cc.config.keys.toggle_sidebar, "<leader>cs")
	MiniTest.expect.equality(cc.config.keys.toggle_diff, "<leader>cd")
	MiniTest.expect.equality(cc.config.integrations.telescope, false)
end

T["init"]["M.lazy table has expected structure"] = function()
	local cc = require("cc-watcher")

	MiniTest.expect.equality(type(cc.lazy), "table")
	MiniTest.expect.equality(type(cc.lazy.cmd), "table")
	MiniTest.expect.equality(type(cc.lazy.keys), "table")
	MiniTest.expect.equality(type(cc.lazy.event), "table")

	-- cmd contains all 6 commands
	local cmds = {}
	for _, c in ipairs(cc.lazy.cmd) do cmds[c] = true end
	MiniTest.expect.equality(cmds["ClaudeSidebar"], true)
	MiniTest.expect.equality(cmds["ClaudeDiff"], true)
	MiniTest.expect.equality(cmds["ClaudeTelescope"], true)
	MiniTest.expect.equality(cmds["ClaudeFzf"], true)
	MiniTest.expect.equality(cmds["ClaudeTrouble"], true)
	MiniTest.expect.equality(cmds["ClaudeDiffview"], true)

	-- keys has 2 entries with desc
	MiniTest.expect.equality(#cc.lazy.keys, 2)
	MiniTest.expect.equality(type(cc.lazy.keys[1].desc), "string")
	MiniTest.expect.equality(type(cc.lazy.keys[2].desc), "string")

	-- event has BufReadPost and BufNewFile
	local events = {}
	for _, e in ipairs(cc.lazy.event) do events[e] = true end
	MiniTest.expect.equality(events["BufReadPost"], true)
	MiniTest.expect.equality(events["BufNewFile"], true)
end

T["init"]["statusline() returns empty string when no changes"] = function()
	local cc = require("cc-watcher")
	local result = cc.statusline()
	MiniTest.expect.equality(type(result), "string")
end

return T
