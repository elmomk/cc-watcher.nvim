local T = MiniTest.new_set()

local session = require("cc-watcher.session")

T["session"] = MiniTest.new_set({
	hooks = {
		pre_case = function() session._reset() end,
	},
})

T["session"]["parse_chunk extracts Write/Edit file paths"] = function()
	-- Simulate JSONL lines that Claude Code would produce
	local jsonl = table.concat({
		vim.json.encode({
			message = {
				content = {
					{ type = "tool_use", name = "Read", input = { file_path = "/tmp/read.rs" } },
				},
			},
		}),
		vim.json.encode({
			message = {
				content = {
					{ type = "tool_use", name = "Write", input = { file_path = "/tmp/written.rs" } },
				},
			},
		}),
		vim.json.encode({
			message = {
				content = {
					{ type = "tool_use", name = "Edit", input = { file_path = "/tmp/edited.rs" } },
				},
			},
		}),
		vim.json.encode({
			message = {
				content = {
					{ type = "tool_use", name = "Bash", input = { command = "ls" } },
				},
			},
		}),
	}, "\n")

	-- Write to a temp file and use get_edited_files_async
	local tmp = vim.fn.tempname()
	local f = io.open(tmp, "w")
	f:write(jsonl .. "\n")
	f:close()

	local result = nil
	session.get_edited_files_async(tmp, function(files)
		result = files
	end)

	-- Wait for sync completion (it's actually sync in this implementation)
	vim.wait(1000, function() return result ~= nil end)

	MiniTest.expect.equality(#result, 2)
	MiniTest.expect.equality(result[1], "/tmp/written.rs")
	MiniTest.expect.equality(result[2], "/tmp/edited.rs")

	vim.fn.delete(tmp)
end

T["session"]["incremental read only parses new data"] = function()
	local tmp = vim.fn.tempname()

	-- Write initial data
	local f = io.open(tmp, "w")
	f:write(vim.json.encode({
		message = { content = {
			{ type = "tool_use", name = "Write", input = { file_path = "/tmp/first.rs" } },
		}},
	}) .. "\n")
	f:close()

	-- First read
	local r1 = nil
	session.get_edited_files_async(tmp, function(files) r1 = files end)
	vim.wait(1000, function() return r1 ~= nil end)
	MiniTest.expect.equality(#r1, 1)

	-- Append more data
	f = io.open(tmp, "a")
	f:write(vim.json.encode({
		message = { content = {
			{ type = "tool_use", name = "Edit", input = { file_path = "/tmp/second.rs" } },
		}},
	}) .. "\n")
	f:close()

	-- Second read should pick up the new entry
	local r2 = nil
	session.get_edited_files_async(tmp, function(files) r2 = files end)
	vim.wait(1000, function() return r2 ~= nil end)
	MiniTest.expect.equality(#r2, 2)
	MiniTest.expect.equality(r2[2], "/tmp/second.rs")

	vim.fn.delete(tmp)
end

T["session"]["deduplicates file paths"] = function()
	local tmp = vim.fn.tempname()
	local f = io.open(tmp, "w")
	-- Same file edited twice
	for _ = 1, 3 do
		f:write(vim.json.encode({
			message = { content = {
				{ type = "tool_use", name = "Edit", input = { file_path = "/tmp/same.rs" } },
			}},
		}) .. "\n")
	end
	f:close()

	local result = nil
	session.get_edited_files_async(tmp, function(files) result = files end)
	vim.wait(1000, function() return result ~= nil end)

	MiniTest.expect.equality(#result, 1)

	vim.fn.delete(tmp)
end

return T
