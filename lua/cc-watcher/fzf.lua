-- fzf.lua — fzf-lua integration for cc-watcher.nvim
-- Two entry points: changed_files() and hunks().

local M = {}

local function guard()
	local ok, fzf = pcall(require, "fzf-lua")
	if not ok then
		vim.notify("fzf-lua not installed", vim.log.levels.WARN)
		return nil
	end
	return fzf
end

local function relpath(filepath)
	local cwd = vim.fn.getcwd()
	if filepath:sub(1, #cwd) == cwd then return filepath:sub(#cwd + 2) end
	return filepath
end

local function read_file(filepath)
	local fd = vim.uv.fs_open(filepath, "r", 438)
	if not fd then return "" end
	local stat = vim.uv.fs_fstat(fd)
	if not stat or stat.size == 0 then
		vim.uv.fs_close(fd)
		return ""
	end
	local data = vim.uv.fs_read(fd, stat.size, 0) or ""
	vim.uv.fs_close(fd)
	return data
end

local function get_old_text(filepath)
	local snapshots = require("cc-watcher.snapshots")
	local snap = snapshots.get(filepath)
	local old_text = snap and snap.raw or ""
	if old_text == "" then
		local rel = relpath(filepath)
		local lines = vim.fn.systemlist("git show HEAD:" .. vim.fn.shellescape(rel) .. " 2>/dev/null")
		if vim.v.shell_error == 0 then
			old_text = table.concat(lines, "\n") .. "\n"
		end
	end
	return old_text
end

local function compute_unified(filepath)
	local old_text = get_old_text(filepath)
	local new_text = read_file(filepath)
	if old_text == "" and new_text == "" then return nil end
	return vim.diff(old_text, new_text, { result_type = "unified", ctxlen = 3 })
end

local function compute_hunks(filepath)
	local old_text = get_old_text(filepath)
	local new_text = read_file(filepath)
	if old_text == "" and new_text == "" then return nil end
	return vim.diff(old_text, new_text, { result_type = "indices", algorithm = "histogram" })
end

local function file_stats(filepath)
	local hunks = compute_hunks(filepath)
	if not hunks then return 0, 0 end
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

	local files = {}
	local seen = {}

	for filepath in pairs(watcher.get_changed_files()) do
		seen[filepath] = true
		files[#files + 1] = { abs = filepath, rel = relpath(filepath), live = true }
	end

	session.get_claude_edited_files_async(function(session_files)
		for _, filepath in ipairs(session_files or {}) do
			if not seen[filepath] then
				seen[filepath] = true
				files[#files + 1] = { abs = filepath, rel = relpath(filepath), live = false }
			end
		end
		table.sort(files, function(a, b) return a.rel < b.rel end)
		callback(files)
	end)
end

--- Write unified diff to a tmp file and return the path
local function diff_preview_tmpfile(filepath)
	local unified = compute_unified(filepath)
	if not unified or unified == "" then return nil end
	local tmp = vim.fn.tempname() .. ".diff"
	local fd = vim.uv.fs_open(tmp, "w", 438)
	if not fd then return nil end
	vim.uv.fs_write(fd, unified, 0)
	vim.uv.fs_close(fd)
	return tmp
end

--- Parse an fzf entry to extract the absolute filepath
local function parse_file_entry(entry)
	-- Format: "● rel/path (+N/-M)" or "○ rel/path (+N/-M)"
	local rel = entry:match("^[●○]%s+(%S+)")
	if not rel then return nil end
	local cwd = vim.fn.getcwd()
	local abs = cwd .. "/" .. rel
	if vim.uv.fs_stat(abs) then return abs end
	return rel
end

--- Parse a hunk entry to extract filepath and line number
local function parse_hunk_entry(entry)
	-- Format: "rel/path:123 — +N/-M lines"
	local rel, line = entry:match("^(%S+):(%d+)")
	if not rel then return nil, nil end
	local cwd = vim.fn.getcwd()
	local abs = cwd .. "/" .. rel
	if vim.uv.fs_stat(abs) then return abs, tonumber(line) end
	return rel, tonumber(line)
end

function M.changed_files()
	local fzf = guard()
	if not fzf then return end

	collect_files(function(files)
		vim.schedule(function()
			if #files == 0 then
				vim.notify("No changed files", vim.log.levels.INFO)
				return
			end

			local entries = {}
			for _, f in ipairs(files) do
				local indicator = f.live and "\xe2\x97\x8f" or "\xe2\x97\x8b" -- ● / ○
				local add, del = file_stats(f.abs)
				local stats = ""
				if add > 0 or del > 0 then
					stats = " (+" .. add .. "/-" .. del .. ")"
				end
				entries[#entries + 1] = indicator .. " " .. f.rel .. stats
			end

			fzf.fzf_exec(entries, {
				prompt = "Claude Changes> ",
				fzf_opts = { ["--ansi"] = "" },
				previewer = false,
				preview = {
					type = "cmd",
					fn = function(items)
						if not items or #items == 0 then return "" end
						local filepath = parse_file_entry(items[1])
						if not filepath then return "echo 'No preview'" end
						local tmp = diff_preview_tmpfile(filepath)
						if tmp then return "cat " .. vim.fn.shellescape(tmp) end
						return "cat " .. vim.fn.shellescape(filepath)
					end,
				},
				actions = {
					["default"] = function(selected)
						if not selected or #selected == 0 then return end
						local filepath = parse_file_entry(selected[1])
						if not filepath then return end
						vim.cmd("edit " .. vim.fn.fnameescape(filepath))
						require("cc-watcher.diff").show(filepath)
					end,
				},
			})
		end)
	end)
end

function M.hunks()
	local fzf = guard()
	if not fzf then return end

	collect_files(function(files)
		vim.schedule(function()
			local entries = {}
			local hunk_map = {} -- entry string -> { filepath, line }

			for _, f in ipairs(files) do
				local hunks = compute_hunks(f.abs)
				if hunks then
					for _, h in ipairs(hunks) do
						local new_start, new_count, old_count = h[3], h[4], h[2]
						local line = math.max(1, new_start)
						local desc = "+" .. new_count .. "/-" .. old_count .. " lines"
						local entry = f.rel .. ":" .. line .. " \xe2\x80\x94 " .. desc
						entries[#entries + 1] = entry
						hunk_map[entry] = { filepath = f.abs, line = line }
					end
				end
			end

			if #entries == 0 then
				vim.notify("No hunks found", vim.log.levels.INFO)
				return
			end

			fzf.fzf_exec(entries, {
				prompt = "Claude Hunks> ",
				fzf_opts = { ["--ansi"] = "" },
				previewer = false,
				preview = {
					type = "cmd",
					fn = function(items)
						if not items or #items == 0 then return "" end
						local filepath, hunk_line = parse_hunk_entry(items[1])
						if not filepath then return "echo 'No preview'" end
						local start = math.max(1, (hunk_line or 1) - 10)
						local finish = (hunk_line or 1) + 30
						return string.format(
							"sed -n '%d,%dp' %s 2>/dev/null",
							start, finish, vim.fn.shellescape(filepath)
						)
					end,
				},
				actions = {
					["default"] = function(selected)
						if not selected or #selected == 0 then return end
						local info = hunk_map[selected[1]]
						if not info then
							local filepath, line = parse_hunk_entry(selected[1])
							if filepath then
								info = { filepath = filepath, line = line or 1 }
							end
						end
						if not info then return end
						vim.cmd("edit " .. vim.fn.fnameescape(info.filepath))
						pcall(vim.api.nvim_win_set_cursor, 0, { info.line, 0 })
						vim.cmd("normal! zz")
						require("cc-watcher.diff").show(info.filepath)
					end,
				},
			})
		end)
	end)
end

return M
