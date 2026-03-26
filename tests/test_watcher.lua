local T = MiniTest.new_set()

T["watcher"] = MiniTest.new_set({
	hooks = {
		pre_case = function()
			require("cc-watcher.watcher")._reset()
		end,
	},
})

T["watcher"]["should_ignore() filters git directories"] = function()
	local watcher = require("cc-watcher.watcher")
	MiniTest.expect.equality(watcher.should_ignore("/project/.git/objects/abc"), true)
	MiniTest.expect.equality(watcher.should_ignore("/project/node_modules/foo.js"), true)
	MiniTest.expect.equality(watcher.should_ignore("/project/target/debug/build"), true)
	MiniTest.expect.equality(watcher.should_ignore("/project/src/main.rs"), false)
	MiniTest.expect.equality(watcher.should_ignore("/project/file.swp"), true)
	MiniTest.expect.equality(watcher.should_ignore("/project/file.rs~"), true)
end

T["watcher"]["should_ignore() allows normal source files"] = function()
	local watcher = require("cc-watcher.watcher")
	MiniTest.expect.equality(watcher.should_ignore("/home/user/project/src/lib.rs"), false)
	MiniTest.expect.equality(watcher.should_ignore("/home/user/project/Cargo.toml"), false)
	MiniTest.expect.equality(watcher.should_ignore("/home/user/project/tests/test.lua"), false)
end

T["watcher"]["mark_changed() tracks files"] = function()
	local watcher = require("cc-watcher.watcher")
	local changed = {}

	watcher.on_change(function(fp, rel)
		changed[fp] = rel
	end)

	watcher.mark_changed("/tmp/test_file.lua")

	MiniTest.expect.equality(watcher.get_changed_files()["/tmp/test_file.lua"], true)
end

T["watcher"]["mark_changed() fires callback on every change"] = function()
	local watcher = require("cc-watcher.watcher")
	local call_count = 0

	watcher.on_change(function()
		call_count = call_count + 1
	end)

	local before = call_count
	watcher.mark_changed("/tmp/dedup_test.lua")
	watcher.mark_changed("/tmp/dedup_test.lua") -- should fire callback again (re-edit)
	MiniTest.expect.equality(call_count - before, 2)
end

return T
