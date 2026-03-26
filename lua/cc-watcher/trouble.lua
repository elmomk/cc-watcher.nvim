-- trouble.lua — trouble.nvim (v3) source for Claude Code changes
-- Shows changed hunks as a diagnostic-like list.

local M = {}

local util = require("cc-watcher.util")

local function hunk_description(old_count, new_count)
	if old_count == 0 then
		return "+" .. new_count .. " lines (added)"
	elseif new_count == 0 then
		return "-" .. old_count .. " lines (deleted)"
	else
		return "+" .. new_count .. "/-" .. old_count .. " lines (changed)"
	end
end

local function hunk_type(old_count, new_count)
	if old_count == 0 then return "info" end
	if new_count == 0 then return "hint" end
	return "warning"
end

--- Build the list of trouble items from all changed files.
---@return table[] items
function M.items()
	local watcher = require("cc-watcher.watcher")
	local changed = watcher.get_changed_files()
	local items = {}

	for filepath, _ in pairs(changed) do
		local old_text = util.get_old_text(filepath)
		local new_text = util.read_file(filepath)

		if new_text then
			local hunks = util.compute_hunks(old_text, new_text)

			if hunks then
				for _, h in ipairs(hunks) do
					-- h = { old_start, old_count, new_start, new_count }
					local old_count = h[2]
					local new_start = h[3]
					local new_count = h[4]
					items[#items + 1] = {
						filename = filepath,
						lnum = new_start > 0 and new_start or 1,
						col = 0,
						text = hunk_description(old_count, new_count),
						type = hunk_type(old_count, new_count),
						source = "claude",
					}
				end
			end
		elseif old_text ~= "" then
			-- File was deleted
			local line_count = select(2, old_text:gsub("\n", ""))
			items[#items + 1] = {
				filename = filepath,
				lnum = 1,
				col = 0,
				text = "-" .. line_count .. " lines (deleted)",
				type = "hint",
				source = "claude",
			}
		end
	end

	-- Sort by filename then line number
	table.sort(items, function(a, b)
		if a.filename ~= b.filename then return a.filename < b.filename end
		return a.lnum < b.lnum
	end)

	return items
end

--- Source getter — calls cb with current items.
---@param cb fun(items: table[])
function M.get(cb)
	cb(M.items())
end

local _setup_done = false

--- Attempt to register the "claude" source with trouble.nvim v3.
function M.setup()
	if _setup_done then return end
	_setup_done = true

	local ok, trouble = pcall(require, "trouble")
	if not ok then return end

	-- Try registering via trouble.sources table (common v3 pattern)
	if trouble.sources then
		trouble.sources.claude = {
			get = M.get,
		}
	end

	-- Try registering as a mode via the API
	local cfg_ok, config = pcall(require, "trouble.config")
	if cfg_ok and config.setup then
		pcall(config.setup, {
			modes = {
				claude = {
					mode = "claude",
					source = "cc-watcher.trouble",
				},
			},
		})
	end
end

--- Open trouble with the claude source.
function M.open()
	local ok, trouble = pcall(require, "trouble")
	if not ok then
		vim.notify("trouble.nvim not installed", vim.log.levels.WARN)
		return
	end
	trouble.open({ mode = "claude" })
end

return M
