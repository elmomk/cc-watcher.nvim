-- telescope.lua — Telescope pickers for cc-watcher.nvim

local ok = pcall(require, "telescope")
if not ok then
	return {
		changed_files = function() vim.notify("telescope.nvim is required for this feature", vim.log.levels.ERROR) end,
		hunks = function() vim.notify("telescope.nvim is required for this feature", vim.log.levels.ERROR) end,
	}
end

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local previewers = require("telescope.previewers")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local util = require("cc-watcher.util")

local M = {}

local function make_display(entry)
	local indicator = entry.source == "live" and "\xe2\x97\x8f " or "\xe2\x97\x8b "
	local icon = ""
	local has_devicons, devicons = pcall(require, "nvim-web-devicons")
	if has_devicons then
		local ic, hl = devicons.get_icon(entry.filename, nil, { default = true })
		if ic then icon = ic .. " " end
	end
	local stats = ""
	if entry.additions > 0 or entry.deletions > 0 then
		stats = " +" .. entry.additions .. "/-" .. entry.deletions
	end
	return indicator .. icon .. entry.rel .. stats
end

function M.changed_files(opts)
	opts = opts or {}

	util.collect_files(function(files, cwd)
		vim.schedule(function()
			local entries = {}
			for _, f in ipairs(files) do
				local old_text = util.get_old_text(f.abs, cwd)
				local new_text = util.read_file(f.abs) or ""
				local hunks = util.compute_hunks(old_text, new_text)
				local add, del = 0, 0
				if hunks then
					add, del = util.hunk_stats(hunks)
				end
				entries[#entries + 1] = {
					value = f.abs,
					ordinal = f.rel,
					display = make_display,
					rel = f.rel,
					filepath = f.abs,
					filename = vim.fn.fnamemodify(f.abs, ":t"),
					source = f.live and "live" or "session",
					additions = add,
					deletions = del,
				}
			end

			pickers.new(opts, {
				prompt_title = "Claude Changed Files",
				finder = finders.new_table({
					results = entries,
					entry_maker = function(e) return e end,
				}),
				sorter = conf.generic_sorter(opts),
				previewer = previewers.new_buffer_previewer({
					title = "Diff",
					define_preview = function(self, entry)
						local old_text = util.get_old_text(entry.filepath, cwd)
						local new_text = util.read_file(entry.filepath) or ""
						local unified = util.compute_unified(old_text, new_text)
						if not unified or unified == "" then
							vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, { "No changes" })
							return
						end
						local lines = vim.split(unified, "\n", { plain = true })
						vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
						vim.bo[self.state.bufnr].filetype = "diff"
					end,
				}),
				attach_mappings = function(prompt_bufnr, map)
					actions.select_default:replace(function()
						local picker = action_state.get_current_picker(prompt_bufnr)
						local selections = picker:get_multi_selection()
						actions.close(prompt_bufnr)

						if #selections > 0 then
							for _, sel in ipairs(selections) do
								vim.cmd("edit " .. vim.fn.fnameescape(sel.filepath))
							end
						else
							local entry = action_state.get_selected_entry()
							if entry then
								vim.cmd("edit " .. vim.fn.fnameescape(entry.filepath))
								require("cc-watcher.diff").show(entry.filepath)
							end
						end
					end)
					return true
				end,
			}):find()
		end)
	end)
end

function M.hunks(opts)
	opts = opts or {}

	util.collect_files(function(files, cwd)
		vim.schedule(function()
			local entries = {}
			for _, f in ipairs(files) do
				local old_text = util.get_old_text(f.abs, cwd)
				local new_text = util.read_file(f.abs) or ""
				local file_hunks = util.compute_hunks(old_text, new_text)
				if file_hunks then
					for _, h in ipairs(file_hunks) do
						local new_start, new_count, old_count = h[3], h[4], h[2]
						local desc = "+" .. new_count .. "/-" .. old_count .. " lines"
						local line = math.max(1, new_start)
						entries[#entries + 1] = {
							value = f.abs .. ":" .. line,
							ordinal = f.rel .. ":" .. line .. " " .. desc,
							display = f.rel .. ":" .. line .. " \xe2\x80\x94 " .. desc,
							filepath = f.abs,
							filename = vim.fn.fnamemodify(f.abs, ":t"),
							lnum = line,
						}
					end
				end
			end

			pickers.new(opts, {
				prompt_title = "Claude Hunks",
				finder = finders.new_table({
					results = entries,
					entry_maker = function(e) return e end,
				}),
				sorter = conf.generic_sorter(opts),
				previewer = previewers.new_buffer_previewer({
					title = "File Preview",
					define_preview = function(self, entry)
						conf.buffer_previewer_maker(entry.filepath, self.state.bufnr, {
							bufname = entry.filepath,
							callback = function(bufnr)
								pcall(vim.api.nvim_win_set_cursor, self.state.winid, { entry.lnum, 0 })
							end,
						})
					end,
				}),
				attach_mappings = function(prompt_bufnr)
					actions.select_default:replace(function()
						local entry = action_state.get_selected_entry()
						actions.close(prompt_bufnr)
						if entry then
							vim.cmd("edit " .. vim.fn.fnameescape(entry.filepath))
							pcall(vim.api.nvim_win_set_cursor, 0, { entry.lnum, 0 })
							vim.cmd("normal! zz")
							require("cc-watcher.diff").show(entry.filepath)
						end
					end)
					return true
				end,
			}):find()
		end)
	end)
end

return M
