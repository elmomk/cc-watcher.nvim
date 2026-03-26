-- telescope.lua — Telescope pickers for cc-watcher.nvim

local ok = pcall(require, "telescope")
if not ok then return {} end

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local previewers = require("telescope.previewers")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local M = {}

local has_devicons, devicons = pcall(require, "nvim-web-devicons")

local function relpath(filepath, cwd)
	if filepath:sub(1, #cwd) == cwd then return filepath:sub(#cwd + 2) end
	return filepath
end

local function read_file(filepath)
	local fd = vim.uv.fs_open(filepath, "r", 438)
	if not fd then return "" end
	local stat = vim.uv.fs_fstat(fd)
	if not stat then vim.uv.fs_close(fd); return "" end
	local data = vim.uv.fs_read(fd, stat.size, 0) or ""
	vim.uv.fs_close(fd)
	return data
end

local function get_old_text(filepath, cwd)
	local snapshots = require("cc-watcher.snapshots")
	local snap = snapshots.get(filepath)
	local old_text = snap and snap.raw or ""
	if old_text == "" then
		local rel = relpath(filepath, cwd)
		local lines = vim.fn.systemlist("git show HEAD:" .. vim.fn.shellescape(rel) .. " 2>/dev/null")
		if vim.v.shell_error == 0 then old_text = table.concat(lines, "\n") .. "\n" end
	end
	return old_text
end

local function compute_unified(filepath, cwd)
	local old_text = get_old_text(filepath, cwd)
	local new_text = read_file(filepath)
	if old_text == "" and new_text == "" then return nil end
	return vim.diff(old_text, new_text, { result_type = "unified", ctxlen = 3 })
end

local function compute_hunks(filepath, cwd)
	local old_text = get_old_text(filepath, cwd)
	local new_text = read_file(filepath)
	if old_text == "" and new_text == "" then return {} end
	return vim.diff(old_text, new_text, { result_type = "indices", algorithm = "histogram" }) or {}
end

local function file_stats_from_hunks(hunks)
	local add, del = 0, 0
	for _, h in ipairs(hunks) do
		add = add + h[4]
		del = del + h[2]
	end
	return add, del
end

local function collect_files(callback)
	local watcher = require("cc-watcher.watcher")
	local session = require("cc-watcher.session")
	local cwd = vim.fn.getcwd()
	local live = watcher.get_changed_files()
	local merged = {}
	local sources = {}

	for fp in pairs(live) do
		merged[fp] = true
		sources[fp] = "live"
	end

	session.get_claude_edited_files_async(function(session_files)
		for _, fp in ipairs(session_files) do
			if not merged[fp] then
				merged[fp] = true
				sources[fp] = "session"
			end
		end

		local results = {}
		for fp in pairs(merged) do
			results[#results + 1] = { filepath = fp, source = sources[fp] }
		end

		table.sort(results, function(a, b)
			return relpath(a.filepath, cwd) < relpath(b.filepath, cwd)
		end)

		callback(results, cwd)
	end, cwd)
end

local function make_display(entry)
	local indicator = entry.source == "live" and "● " or "○ "
	local icon = ""
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

	collect_files(function(files, cwd)
		vim.schedule(function()
			local entries = {}
			for _, f in ipairs(files) do
				local rel = relpath(f.filepath, cwd)
				local hunks = compute_hunks(f.filepath, cwd)
				local add, del = file_stats_from_hunks(hunks)
				entries[#entries + 1] = {
					value = f.filepath,
					ordinal = rel,
					display = make_display,
					rel = rel,
					filepath = f.filepath,
					filename = vim.fn.fnamemodify(f.filepath, ":t"),
					source = f.source,
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
						local unified = compute_unified(entry.filepath, cwd)
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

	collect_files(function(files, cwd)
		vim.schedule(function()
			local entries = {}
			for _, f in ipairs(files) do
				local rel = relpath(f.filepath, cwd)
				local file_hunks = compute_hunks(f.filepath, cwd)
				for _, h in ipairs(file_hunks) do
					local new_start, new_count, old_count = h[3], h[4], h[2]
					local desc = "+" .. new_count .. "/-" .. old_count .. " lines"
					local line = math.max(1, new_start)
					entries[#entries + 1] = {
						value = f.filepath .. ":" .. line,
						ordinal = rel .. ":" .. line .. " " .. desc,
						display = rel .. ":" .. line .. " — " .. desc,
						filepath = f.filepath,
						filename = vim.fn.fnamemodify(f.filepath, ":t"),
						lnum = line,
					}
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
