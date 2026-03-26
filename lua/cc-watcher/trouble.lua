-- trouble.lua — trouble.nvim (v3) source for Claude Code changes
-- Registers as a proper trouble source with "claude" mode.

local Item = require("trouble.item")
local util = require("cc-watcher.util")

---@class trouble.Source.claude: trouble.Source
local M = {}

M.config = {
	modes = {
		claude = {
			desc = "Claude Code Changes",
			source = "claude",
			groups = {
				{ "filename", format = "{file_icon} {filename} {count}" },
			},
			sort = { "severity", "filename", "pos" },
			format = "{severity_icon} {text:ts} {pos}",
		},
	},
}

local severity_map = {
	added = vim.diagnostic.severity.INFO,
	deleted = vim.diagnostic.severity.ERROR,
	changed = vim.diagnostic.severity.WARN,
}

local function hunk_description(old_count, new_count)
	if old_count == 0 then
		return "+" .. new_count .. " lines (added)"
	elseif new_count == 0 then
		return "-" .. old_count .. " lines (deleted)"
	else
		return "+" .. new_count .. "/-" .. old_count .. " lines (changed)"
	end
end

local function hunk_severity(old_count, new_count)
	if old_count == 0 then return severity_map.added end
	if new_count == 0 then return severity_map.deleted end
	return severity_map.changed
end

---@param cb trouble.Source.Callback
---@param ctx trouble.Source.ctx
function M.get(cb, ctx)
	util.collect_files(function(files)
		vim.schedule(function()
			local items = {} ---@type trouble.Item[]

			for _, f in ipairs(files) do
				local old_text = util.get_old_text(f.abs)
				local new_text = util.read_file(f.abs)

				if new_text then
					local hunks = util.compute_hunks(old_text, new_text)
					if hunks then
						for _, h in ipairs(hunks) do
							local old_count = h[2]
							local new_start = h[3]
							local new_count = h[4]
							local row = new_start > 0 and new_start or 1

							items[#items + 1] = Item.new({
								pos = { row, 0 },
								end_pos = { row + math.max(new_count, 1) - 1, 0 },
								text = hunk_description(old_count, new_count),
								severity = hunk_severity(old_count, new_count),
								filename = f.abs,
								source = "claude",
								item = {
									old_count = old_count,
									new_count = new_count,
								},
							})
						end
					end
				end
			end

			Item.add_id(items, { "severity" })
			Item.add_text(items, { mode = "full" })
			cb(items)
		end)
	end)
end

return M
