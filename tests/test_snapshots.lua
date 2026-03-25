local T = MiniTest.new_set()

local snapshots = require("cc-watcher.snapshots")

T["snapshots"] = MiniTest.new_set({
	hooks = {
		pre_case = function() snapshots.clear() end,
		post_case = function() snapshots.clear() end,
	},
})

T["snapshots"]["take() captures file contents"] = function()
	local tmp = vim.fn.tempname()
	vim.fn.writefile({ "hello", "world" }, tmp)

	snapshots.take(tmp)

	MiniTest.expect.equality(snapshots.has(tmp), true)
	local snap = snapshots.get(tmp)
	MiniTest.expect.equality(snap.lines[1], "hello")
	MiniTest.expect.equality(snap.lines[2], "world")
	MiniTest.expect.equality(type(snap.raw), "string")
	MiniTest.expect.equality(type(snap.mtime), "number")

	vim.fn.delete(tmp)
end

T["snapshots"]["take() stores raw content for fast comparison"] = function()
	local tmp = vim.fn.tempname()
	vim.fn.writefile({ "line1", "line2" }, tmp)

	snapshots.take(tmp)
	local snap = snapshots.get(tmp)

	-- Raw should contain newlines
	MiniTest.expect.equality(snap.raw:find("line1\nline2", 1, true) ~= nil, true)

	vim.fn.delete(tmp)
end

T["snapshots"]["get() returns nil for unknown file"] = function()
	MiniTest.expect.equality(snapshots.get("/nonexistent/file.lua"), nil)
end

T["snapshots"]["has() returns false for unknown file"] = function()
	MiniTest.expect.equality(snapshots.has("/nonexistent/file.lua"), false)
end

T["snapshots"]["remove() deletes snapshot"] = function()
	local tmp = vim.fn.tempname()
	vim.fn.writefile({ "data" }, tmp)

	snapshots.take(tmp)
	MiniTest.expect.equality(snapshots.has(tmp), true)

	snapshots.remove(tmp)
	MiniTest.expect.equality(snapshots.has(tmp), false)

	vim.fn.delete(tmp)
end

T["snapshots"]["clear() removes all snapshots"] = function()
	local t1 = vim.fn.tempname()
	local t2 = vim.fn.tempname()
	vim.fn.writefile({ "a" }, t1)
	vim.fn.writefile({ "b" }, t2)

	snapshots.take(t1)
	snapshots.take(t2)
	MiniTest.expect.equality(snapshots.count(), 2)

	snapshots.clear()
	MiniTest.expect.equality(snapshots.count(), 0)
	MiniTest.expect.equality(snapshots.has(t1), false)

	vim.fn.delete(t1)
	vim.fn.delete(t2)
end

T["snapshots"]["LRU evicts oldest when over capacity"] = function()
	-- Create 102 temp files, snapshot all of them
	local files = {}
	for i = 1, 102 do
		local tmp = vim.fn.tempname()
		vim.fn.writefile({ "file" .. i }, tmp)
		files[i] = tmp
		snapshots.take(tmp)
	end

	-- Should have evicted the first 2
	MiniTest.expect.equality(snapshots.count(), 100)
	MiniTest.expect.equality(snapshots.has(files[1]), false)
	MiniTest.expect.equality(snapshots.has(files[2]), false)
	MiniTest.expect.equality(snapshots.has(files[3]), true)
	MiniTest.expect.equality(snapshots.has(files[102]), true)

	for _, f in ipairs(files) do vim.fn.delete(f) end
end

return T
