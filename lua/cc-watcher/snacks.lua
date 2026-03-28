-- snacks.lua — snacks.nvim pickers for cc-watcher.nvim

local util = require("cc-watcher.util")

local M = {}

local diff_ns = vim.api.nvim_create_namespace("cc_watcher_diff")
local preview_cache = {} -- filepath -> { unified = string, mtime = number }

function M.changed_files()
	local ok, Snacks = pcall(require, "snacks")
	if not ok then
		vim.notify("snacks.nvim is required for this feature", vim.log.levels.ERROR)
		return
	end

	util.collect_files(function(files, cwd)
		vim.schedule(function()
			-- Find the most recently modified file
			local best_mtime, latest_file = 0, nil
			for _, f in ipairs(files) do
				local st = vim.uv.fs_stat(f.abs)
				if st and st.mtime.sec > best_mtime then
					best_mtime = st.mtime.sec
					latest_file = f.abs
				end
			end

			local items = {}
			for _, f in ipairs(files) do
				local old_text = util.get_old_text(f.abs, cwd)
				local new_text = util.read_file(f.abs) or ""
				local hunks = util.compute_hunks(old_text, new_text)
				local add, del = 0, 0
				if hunks then add, del = util.hunk_stats(hunks) end

				local is_latest = latest_file and f.abs == latest_file
				local indicator = is_latest and "▶ " or (f.live and "● " or "○ ")
				local indicator_hl = is_latest and "ClaudeFileLatest" or (f.live and "ClaudeLive" or "ClaudeSession")
				local stats = ""
				if add > 0 or del > 0 then stats = " +" .. add .. "/-" .. del end

				items[#items + 1] = {
					text = f.rel,
					file = f.abs,
					indicator = indicator,
					indicator_hl = indicator_hl,
					stats = stats,
					rel = f.rel,
					live = f.live,
					is_latest = is_latest,
					cwd = cwd,
				}
			end

			Snacks.picker({
				title = "Claude Changed Files",
				items = items,
				format = function(item)
					local ret = {}
					ret[#ret + 1] = { item.indicator, item.indicator_hl }
					ret[#ret + 1] = { item.rel, item.is_latest and "ClaudeFileLatest" or nil }
					if item.stats ~= "" then
						ret[#ret + 1] = { item.stats, "ClaudeStats" }
					end
					return ret
				end,
				preview = function(ctx)
					require("cc-watcher.highlights").setup()
					local item = ctx.item
					local stat = vim.uv.fs_stat(item.file)
					local mtime = stat and stat.mtime.sec or 0
					local cached = preview_cache[item.file]

					local unified
					if cached and cached.mtime == mtime then
						unified = cached.unified
					else
						local old_text = util.get_old_text(item.file, item.cwd)
						local new_text = util.read_file(item.file) or ""
						unified = util.compute_unified(old_text, new_text)
						preview_cache[item.file] = { unified = unified, mtime = mtime }
					end

					ctx.preview:reset()
					if unified and unified ~= "" then
						local lines = vim.split(unified, "\n", { plain = true })
						ctx.preview:set_lines(lines)
						-- Defer extmarks so they survive snacks' internal buffer setup
						local buf = ctx.preview.win.buf
						vim.schedule(function()
							if not vim.api.nvim_buf_is_valid(buf) then return end
							vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
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
									pcall(vim.api.nvim_buf_set_extmark, buf, diff_ns, i - 1, 0, {
										line_hl_group = hl,
										priority = 200,
									})
								end
							end
						end)
					else
						ctx.preview:set_lines({ "No changes" })
					end
				end,
				confirm = function(picker, item)
					picker:close()
					vim.cmd("edit " .. vim.fn.fnameescape(item.file))
					require("cc-watcher.diff").show(item.file, { jump = true })
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
			-- Find the most recently modified file
			local best_mtime, latest_file = 0, nil
			for _, f in ipairs(files) do
				local st = vim.uv.fs_stat(f.abs)
				if st and st.mtime.sec > best_mtime then
					best_mtime = st.mtime.sec
					latest_file = f.abs
				end
			end

			local items = {}
			for _, f in ipairs(files) do
				local is_latest = latest_file and f.abs == latest_file
				local old_text = util.get_old_text(f.abs, cwd)
				local new_text = util.read_file(f.abs) or ""
				local file_hunks = util.compute_hunks(old_text, new_text)
				if file_hunks then
					for _, h in ipairs(file_hunks) do
						local line = math.max(1, h[3])
						local desc = "+" .. h[4] .. "/-" .. h[2] .. " lines"
						local indicator = is_latest and "▶ " or "  "
						local indicator_hl = is_latest and "ClaudeFileLatest" or nil
						items[#items + 1] = {
							text = f.rel .. ":" .. line .. " " .. desc,
							file = f.abs,
							pos = { line, 0 },
							desc = desc,
							rel = f.rel,
							indicator = indicator,
							indicator_hl = indicator_hl,
							is_latest = is_latest,
						}
					end
				end
			end

			Snacks.picker({
				title = "Claude Hunks",
				items = items,
				format = function(item)
					local ret = {}
					ret[#ret + 1] = { item.indicator, item.indicator_hl }
					ret[#ret + 1] = { item.rel, item.is_latest and "ClaudeFileLatest" or nil }
					ret[#ret + 1] = { ":" .. item.pos[1] .. " ", "Comment" }
					ret[#ret + 1] = { item.desc, "ClaudeStats" }
					return ret
				end,
				confirm = function(picker, item)
					picker:close()
					vim.cmd("edit " .. vim.fn.fnameescape(item.file))
					pcall(vim.api.nvim_win_set_cursor, 0, { item.pos[1], 0 })
					vim.cmd("normal! zz")
					require("cc-watcher.diff").show(item.file, { jump = true })
				end,
			})
		end)
	end)
end

return M
