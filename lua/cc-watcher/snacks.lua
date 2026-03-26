-- snacks.lua — Snacks picker integration for cc-watcher.nvim

local ok = pcall(require, "snacks")
if not ok then return {} end

local M = {}

local function relpath(filepath, cwd)
	if filepath:sub(1, #cwd) == cwd then return filepath:sub(#cwd + 2) end
	-- Try git root for worktree paths
	local dir = vim.fn.fnamemodify(filepath, ":h")
	local root = vim.fn.systemlist("git -C " .. vim.fn.shellescape(dir) .. " rev-parse --show-toplevel 2>/dev/null")
	if vim.v.shell_error == 0 and root[1] then
		local git_root = root[1]
		if filepath:sub(1, #git_root) == git_root then
			return filepath:sub(#git_root + 2)
		end
	end
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

local function git_show_head(filepath)
	local dir = vim.fn.fnamemodify(filepath, ":h")
	local root = vim.fn.systemlist("git -C " .. vim.fn.shellescape(dir) .. " rev-parse --show-toplevel 2>/dev/null")
	local rel = filepath
	if vim.v.shell_error == 0 and root[1] then
		local git_root = root[1]
		if filepath:sub(1, #git_root) == git_root then
			rel = filepath:sub(#git_root + 2)
		end
	end
	return vim.fn.systemlist("git -C " .. vim.fn.shellescape(dir) .. " show HEAD:" .. vim.fn.shellescape(rel) .. " 2>/dev/null")
end

local function get_old_text(filepath)
	local lines = git_show_head(filepath)
	if vim.v.shell_error == 0 and #lines > 0 then return table.concat(lines, "\n") .. "\n" end

	local snapshots = require("cc-watcher.snapshots")
	local snap = snapshots.get(filepath)
	if snap then return snap.raw end
	return ""
end

local function compute_unified(filepath, cwd)
	local old_text = get_old_text(filepath)
	local new_text = read_file(filepath)
	if old_text == "" and new_text == "" then return nil end
	local rel = relpath(filepath, cwd)
	local diff = vim.diff(old_text, new_text, { result_type = "unified", ctxlen = 3 })
	if not diff or diff == "" then return nil end
	-- Prepend git-style headers so the snacks diff renderer can parse it
	return "--- a/" .. rel .. "\n+++ b/" .. rel .. "\n" .. diff
end

local function compute_hunks(filepath, cwd)
	local old_text = get_old_text(filepath)
	local new_text = read_file(filepath)
	if old_text == "" and new_text == "" then return {} end
	return vim.diff(old_text, new_text, { result_type = "indices", algorithm = "histogram" }) or {}
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

function M.changed_files()
	collect_files(function(files, cwd)
		vim.schedule(function()
			local items = {}
			for _, f in ipairs(files) do
				local rel = relpath(f.filepath, cwd)
				local hunks = compute_hunks(f.filepath, cwd)
				local add, del = 0, 0
				for _, h in ipairs(hunks) do
					add = add + h[4]
					del = del + h[2]
				end
				local indicator = f.source == "live" and "● " or "○ "
				local stats = ""
				if add > 0 or del > 0 then
					stats = " +" .. add .. "/-" .. del
				end
				items[#items + 1] = {
					text = indicator .. rel .. stats,
					file = f.filepath,
					filepath = f.filepath,
					source = f.source,
				}
			end

			Snacks.picker({
				title = "Claude Changed Files",
				items = items,
				format = "text",
				preview = function(ctx)
					require("cc-watcher.highlights").setup()
					local unified = compute_unified(ctx.item.filepath, cwd)
					if not unified or unified == "" then
						ctx.preview:set_lines({ "No changes" })
						return
					end
					local lines = vim.split(unified, "\n", { plain = true })
					ctx.preview:set_lines(lines)
					local ns = vim.api.nvim_create_namespace("cc_watcher_diff")
					for i, line in ipairs(lines) do
						local hl = nil
						if line:match("^%+") and not line:match("^%+%+%+") then
							hl = "ClaudeDiffAdd"
						elseif line:match("^%-") and not line:match("^%-%-%-") then
							hl = "ClaudeDiffDelete"
						elseif line:match("^@@") then
							hl = "ClaudeDiffChange"
						elseif line:match("^%-%-%- ") or line:match("^%+%+%+ ") then
							hl = "ClaudeDiffDeleteNr"
						end
						if hl then
							pcall(vim.api.nvim_buf_set_extmark, ctx.buf, ns, i - 1, 0, {
								line_hl_group = hl,
							})
						end
					end
				end,
				confirm = function(picker, item)
					picker:close()
					if item then
						vim.cmd("edit " .. vim.fn.fnameescape(item.filepath))
						require("cc-watcher.diff").show(item.filepath)
					end
				end,
			})
		end)
	end)
end

function M.hunks()
	collect_files(function(files, cwd)
		vim.schedule(function()
			local items = {}
			for _, f in ipairs(files) do
				local rel = relpath(f.filepath, cwd)
				local file_hunks = compute_hunks(f.filepath, cwd)
				for _, h in ipairs(file_hunks) do
					local new_start, new_count, old_count = h[3], h[4], h[2]
					local desc = "+" .. new_count .. "/-" .. old_count .. " lines"
					local line = math.max(1, new_start)
					items[#items + 1] = {
						text = rel .. ":" .. line .. " — " .. desc,
						file = f.filepath,
						filepath = f.filepath,
						pos = { line, 0 },
					}
				end
			end

			Snacks.picker({
				title = "Claude Hunks",
				items = items,
				format = "text",
				preview = "file",
				confirm = function(picker, item)
					picker:close()
					if item then
						vim.cmd("edit " .. vim.fn.fnameescape(item.filepath))
						pcall(vim.api.nvim_win_set_cursor, 0, { item.pos[1], 0 })
						vim.cmd("normal! zz")
						require("cc-watcher.diff").show(item.filepath)
					end
				end,
			})
		end)
	end)
end

return M
