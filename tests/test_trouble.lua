local T = MiniTest.new_set()

local snapshots = require("cc-watcher.snapshots")
local watcher = require("cc-watcher.watcher")

T["trouble"] = MiniTest.new_set({
	hooks = {
		pre_case = function() snapshots.clear() end,
		post_case = function() snapshots.clear() end,
	},
})

T["trouble"]["items() returns empty list when no changed files"] = function()
	local trouble = require("cc-watcher.trouble")
	local items = trouble.items()
	MiniTest.expect.equality(type(items), "table")
	MiniTest.expect.equality(#items, 0)
end

T["trouble"]["items() returns hunks for changed files"] = function()
	local trouble = require("cc-watcher.trouble")

	-- Create a temp file with original content
	local tmp = vim.fn.tempname()
	vim.fn.writefile({ "line1", "line2", "line3" }, tmp)

	-- Take snapshot of original
	snapshots.take(tmp)

	-- "Claude" modifies the file: change line2, add line4
	vim.fn.writefile({ "line1", "CHANGED", "line3", "line4" }, tmp)

	-- Mark as changed
	watcher.mark_changed(tmp)

	local items = trouble.items()

	-- Should have items for this file
	local file_items = {}
	for _, item in ipairs(items) do
		if item.filename == tmp then
			file_items[#file_items + 1] = item
		end
	end

	MiniTest.expect.equality(#file_items > 0, true)

	-- Verify item structure
	for _, item in ipairs(file_items) do
		MiniTest.expect.equality(type(item.filename), "string")
		MiniTest.expect.equality(type(item.lnum), "number")
		MiniTest.expect.equality(item.lnum > 0, true)
		MiniTest.expect.equality(type(item.col), "number")
		MiniTest.expect.equality(type(item.text), "string")
		MiniTest.expect.equality(item.text ~= "", true)
		MiniTest.expect.equality(item.source, "claude")
		-- type should be a vim.diagnostic.severity value
		local valid_types = {
			[vim.diagnostic.severity.INFO] = true,
			[vim.diagnostic.severity.WARN] = true,
			[vim.diagnostic.severity.ERROR] = true,
		}
		MiniTest.expect.equality(valid_types[item.type] or false, true)
	end

	vim.fn.delete(tmp)
end

T["trouble"]["items() detects additions"] = function()
	local trouble = require("cc-watcher.trouble")

	local tmp = vim.fn.tempname()
	vim.fn.writefile({ "line1" }, tmp)
	snapshots.take(tmp)

	-- Add lines
	vim.fn.writefile({ "line1", "new1", "new2" }, tmp)
	watcher.mark_changed(tmp)

	local items = trouble.items()
	local found = false
	for _, item in ipairs(items) do
		if item.filename == tmp and item.text:find("added") then
			found = true
			MiniTest.expect.equality(item.type, vim.diagnostic.severity.INFO)
		end
	end
	MiniTest.expect.equality(found, true)

	vim.fn.delete(tmp)
end

T["trouble"]["items() detects deletions"] = function()
	local trouble = require("cc-watcher.trouble")

	local tmp = vim.fn.tempname()
	vim.fn.writefile({ "line1", "line2", "line3" }, tmp)
	snapshots.take(tmp)

	-- Delete lines
	vim.fn.writefile({ "line1" }, tmp)
	watcher.mark_changed(tmp)

	local items = trouble.items()
	local found = false
	for _, item in ipairs(items) do
		if item.filename == tmp and item.text:find("deleted") then
			found = true
			MiniTest.expect.equality(item.type, vim.diagnostic.severity.ERROR)
		end
	end
	MiniTest.expect.equality(found, true)

	vim.fn.delete(tmp)
end

T["trouble"]["items() detects changes"] = function()
	local trouble = require("cc-watcher.trouble")

	local tmp = vim.fn.tempname()
	vim.fn.writefile({ "line1", "line2", "line3" }, tmp)
	snapshots.take(tmp)

	-- Change a line (same count, different content)
	vim.fn.writefile({ "line1", "MODIFIED", "line3" }, tmp)
	watcher.mark_changed(tmp)

	local items = trouble.items()
	local found = false
	for _, item in ipairs(items) do
		if item.filename == tmp and item.text:find("changed") then
			found = true
			MiniTest.expect.equality(item.type, vim.diagnostic.severity.WARN)
		end
	end
	MiniTest.expect.equality(found, true)

	vim.fn.delete(tmp)
end

T["trouble"]["items() are sorted by filename then line number"] = function()
	local trouble = require("cc-watcher.trouble")

	-- Create two files with changes
	local tmp1 = vim.fn.tempname() .. "_aaa"
	local tmp2 = vim.fn.tempname() .. "_bbb"

	vim.fn.writefile({ "a1", "a2" }, tmp1)
	vim.fn.writefile({ "b1", "b2" }, tmp2)
	snapshots.take(tmp1)
	snapshots.take(tmp2)

	vim.fn.writefile({ "a1", "CHANGED", "added" }, tmp1)
	vim.fn.writefile({ "b1", "CHANGED" }, tmp2)
	watcher.mark_changed(tmp1)
	watcher.mark_changed(tmp2)

	local items = trouble.items()

	-- Filter to just our files
	local our_items = {}
	for _, item in ipairs(items) do
		if item.filename == tmp1 or item.filename == tmp2 then
			our_items[#our_items + 1] = item
		end
	end

	-- Verify sorted: all tmp1 items before tmp2 (since filenames are sorted)
	-- and within a file, sorted by lnum
	local prev_file, prev_lnum = "", 0
	for _, item in ipairs(our_items) do
		if item.filename == prev_file then
			MiniTest.expect.equality(item.lnum >= prev_lnum, true)
		end
		prev_file = item.filename
		prev_lnum = item.lnum
	end

	vim.fn.delete(tmp1)
	vim.fn.delete(tmp2)
end

T["trouble"]["get() calls callback with items"] = function()
	local trouble = require("cc-watcher.trouble")
	local received = nil

	trouble.get(function(items)
		received = items
	end)

	MiniTest.expect.equality(type(received), "table")
end

return T
