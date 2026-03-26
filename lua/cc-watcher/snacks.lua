-- snacks.lua — snacks.nvim pickers for cc-watcher.nvim

local util = require("cc-watcher.util")

local M = {}

function M.changed_files()
	local ok, Snacks = pcall(require, "snacks")
	if not ok then
		vim.notify("snacks.nvim is required for this feature", vim.log.levels.ERROR)
		return
	end

	util.collect_files(function(files, cwd)
		vim.schedule(function()
			local items = {}
			for _, f in ipairs(files) do
				local old_text = util.get_old_text(f.abs, cwd)
				local new_text = util.read_file(f.abs) or ""
				local hunks = util.compute_hunks(old_text, new_text)
				local add, del = 0, 0
				if hunks then add, del = util.hunk_stats(hunks) end

				local indicator = f.live and "● " or "○ "
				local stats = ""
				if add > 0 or del > 0 then stats = " +" .. add .. "/-" .. del end

				items[#items + 1] = {
					text = f.rel,
					file = f.abs,
					indicator = indicator,
					stats = stats,
					rel = f.rel,
					live = f.live,
					cwd = cwd,
				}
			end

			Snacks.picker({
				title = "Claude Changed Files",
				items = items,
				format = function(item)
					local ret = {}
					ret[#ret + 1] = { item.indicator, item.live and "ClaudeLive" or "ClaudeSession" }
					ret[#ret + 1] = { item.rel }
					if item.stats ~= "" then
						ret[#ret + 1] = { item.stats, "ClaudeStats" }
					end
					return ret
				end,
				preview = function(ctx)
					require("cc-watcher.highlights").setup()
					local item = ctx.item
					local old_text = util.get_old_text(item.file, item.cwd)
					local new_text = util.read_file(item.file) or ""
					local unified = util.compute_unified(old_text, new_text)
					ctx.preview:reset()
					if unified and unified ~= "" then
						local lines = vim.split(unified, "\n", { plain = true })
						ctx.preview:set_lines(lines)
						local buf = ctx.preview.win.buf
						local ns = vim.api.nvim_create_namespace("cc_watcher_diff")
						for i, line in ipairs(lines) do
							local hl = nil
							if line:match("^%+") and not line:match("^%+%+%+") then
								hl = "ClaudeDiffAdd"
							elseif line:match("^%-") and not line:match("^%-%-%-") then
								hl = "ClaudeDiffDelete"
							elseif line:match("^@@") then
								hl = "ClaudeDiffChange"
							end
							if hl then
								vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
									line_hl_group = hl,
									priority = 200,
								})
							end
						end
					else
						ctx.preview:set_lines({ "No changes" })
					end
				end,
				confirm = function(picker, item)
					picker:close()
					vim.cmd("edit " .. vim.fn.fnameescape(item.file))
					require("cc-watcher.diff").show(item.file)
				end,
			})
		end)
	end)
end

function M.hunks()
	local ok, Snacks = pcall(require, "snacks")
	if not ok then
		vim.notify("snacks.nvim is required for this feature", vim.log.levels.ERROR)
		return
	end

	util.collect_files(function(files, cwd)
		vim.schedule(function()
			local items = {}
			for _, f in ipairs(files) do
				local old_text = util.get_old_text(f.abs, cwd)
				local new_text = util.read_file(f.abs) or ""
				local file_hunks = util.compute_hunks(old_text, new_text)
				if file_hunks then
					for _, h in ipairs(file_hunks) do
						local line = math.max(1, h[3])
						local desc = "+" .. h[4] .. "/-" .. h[2] .. " lines"
						items[#items + 1] = {
							text = f.rel .. ":" .. line .. " " .. desc,
							file = f.abs,
							pos = { line, 0 },
							desc = desc,
							rel = f.rel,
						}
					end
				end
			end

			Snacks.picker({
				title = "Claude Hunks",
				items = items,
				confirm = function(picker, item)
					picker:close()
					vim.cmd("edit " .. vim.fn.fnameescape(item.file))
					pcall(vim.api.nvim_win_set_cursor, 0, { item.pos[1], 0 })
					vim.cmd("normal! zz")
					require("cc-watcher.diff").show(item.file)
				end,
			})
		end)
	end)
end

return M
