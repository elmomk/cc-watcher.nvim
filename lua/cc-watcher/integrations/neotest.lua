-- Auto-run tests when Claude edits test files (requires neotest)
local M = {}
local _done = false

-- Common test file patterns
local test_patterns = {
	"_test%.",   -- Go, Rust
	"_spec%.",   -- Ruby, JS
	"%.test%.",  -- JS/TS
	"%.spec%.",  -- JS/TS
	"test_",     -- Python
	"/tests/",   -- directory convention
	"/spec/",    -- Ruby convention
	"/__tests__/", -- Jest convention
}

function M.setup()
	if _done then return end
	_done = true

	local ok = pcall(require, "neotest")
	if not ok then return end

	require("cc-watcher.watcher").on_change(function(filepath, relpath)
		local is_test = false
		for _, pattern in ipairs(test_patterns) do
			if relpath:find(pattern) then
				is_test = true
				break
			end
		end
		if not is_test then return end

		vim.schedule(function()
			local neotest = require("neotest")
			neotest.run.run(filepath)
			vim.notify("󰚩 Running tests: " .. relpath, vim.log.levels.INFO)
		end)
	end)
end

return M
