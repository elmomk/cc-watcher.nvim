-- fzf.lua — fzf-lua integration for cc-watcher.nvim
-- Two entry points: changed_files() and hunks().

local M = {}

local util = require("cc-watcher.util")

local preview_cache = {} -- filepath -> { tmp = tmppath, mtime = number }

local function guard()
	local ok, fzf = pcall(require, "fzf-lua")
	if not ok then
		vim.notify("fzf-lua not installed", vim.log.levels.WARN)
		return nil
	end
	return fzf
end

--- Parse an fzf entry to extract the absolute filepath
local function parse_file_entry(entry)
	-- Format: "● rel/path (+N/-M)" or "○ rel/path (+N/-M)"
	local rel = entry:match("^[●○]%s+(%S+)")
	if not rel then return nil end
	local cwd = vim.uv.cwd()
	local abs = cwd .. "/" .. rel
	if vim.uv.fs_stat(abs) then return abs end
	return rel
end

--- Parse a hunk entry to extract filepath and line number
local function parse_hunk_entry(entry)
	-- Format: "rel/path:123 — +N/-M lines"
	local rel, line = entry:match("^(%S+):(%d+)")
	if not rel then return nil, nil end
	local cwd = vim.uv.cwd()
	local abs = cwd .. "/" .. rel
	if vim.uv.fs_stat(abs) then return abs, tonumber(line) end
	return rel, tonumber(line)
end

--- Write unified diff to a tmp file and return the path (cached per filepath)
local function diff_preview_tmpfile(filepath)
	local stat = vim.uv.fs_stat(filepath)
	local mtime = stat and stat.mtime.sec or 0

	local cached = preview_cache[filepath]
	if cached and cached.mtime == mtime then
		return cached.tmp
	end

	local old_text = util.get_old_text(filepath)
	local new_text = util.read_file(filepath) or ""
	local unified = util.compute_unified(old_text, new_text)
	if not unified or unified == "" then return nil end

	local tmp = cached and cached.tmp or (vim.fn.tempname() .. ".diff")
	local fd = vim.uv.fs_open(tmp, "w", util.FILE_MODE)
	if not fd then return nil end
	vim.uv.fs_write(fd, unified, 0)
	vim.uv.fs_close(fd)

	preview_cache[filepath] = { tmp = tmp, mtime = mtime }
	return tmp
end

-- Cleanup cached tmp files on exit
local _cleanup_registered = false

if not _cleanup_registered then
	_cleanup_registered = true
	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			for _, entry in pairs(preview_cache) do
				pcall(vim.uv.fs_unlink, entry.tmp)
			end
			preview_cache = {}
		end,
	})
end

function M.changed_files()
	local fzf = guard()
	if not fzf then return end

	util.collect_files(function(files, cwd)
		vim.schedule(function()
			if #files == 0 then
				vim.notify("No changed files", vim.log.levels.INFO)
				return
			end

			local entries = {}
			for _, f in ipairs(files) do
				local indicator = f.live and "\xe2\x97\x8f" or "\xe2\x97\x8b" -- ● / ○
				local old_text = util.get_old_text(f.abs)
				local new_text = util.read_file(f.abs) or ""
				local hunks = util.compute_hunks(old_text, new_text)
				local add, del = 0, 0
				if hunks then
					add, del = util.hunk_stats(hunks)
				end
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

	util.collect_files(function(files, cwd)
		vim.schedule(function()
			local entries = {}
			local hunk_map = {} -- entry string -> { filepath, line }

			for _, f in ipairs(files) do
				local old_text = util.get_old_text(f.abs)
				local new_text = util.read_file(f.abs) or ""
				local hunks = util.compute_hunks(old_text, new_text)
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
