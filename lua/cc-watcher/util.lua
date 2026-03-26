-- util.lua — Shared helpers for cc-watcher.nvim
-- Single source of truth for relpath, file I/O, diff helpers, and file collection.

local M = {}

M.FILE_MODE = 384 -- octal 0600: rw for owner only
M.READ_MODE = 438 -- octal 0666: rw for all (used for fs_open read)

local git_toplevel_cache = {} -- dir -> toplevel string or false
local git_show_cache = {} -- git_rel -> string

--- Invalidate cached git HEAD content (call after git operations)
function M.invalidate_git_cache()
	git_show_cache = {}
end

vim.api.nvim_create_autocmd("FocusGained", {
	callback = function() git_show_cache = {} end,
})

--- Compute relative path from cwd
---@param filepath string absolute path
---@param cwd string|nil defaults to vim.uv.cwd()
---@return string
function M.relpath(filepath, cwd)
	cwd = cwd or vim.uv.cwd()
	if filepath:sub(1, #cwd + 1) == cwd .. "/" then return filepath:sub(#cwd + 2) end
	-- Fallback: try git root for worktree paths
	local git_rel = M.git_relpath(filepath)
	if git_rel then return git_rel end
	return filepath
end

--- Get path relative to git repo root (works in worktrees)
---@param filepath string absolute path
---@return string|nil relative path from git root
---@return string|nil directory used for git commands
function M.git_relpath(filepath)
	local dir = vim.fn.fnamemodify(filepath, ":h")
	local cached = git_toplevel_cache[dir]
	if cached == nil then
		local toplevel = vim.fn.systemlist("git -C " .. vim.fn.shellescape(dir) .. " rev-parse --show-toplevel 2>/dev/null")[1]
		if vim.v.shell_error ~= 0 or not toplevel or toplevel == "" then
			git_toplevel_cache[dir] = false
		else
			git_toplevel_cache[dir] = toplevel
		end
		cached = git_toplevel_cache[dir]
	end
	if not cached then return nil, nil end
	if filepath:sub(1, #cached + 1) == cached .. "/" then
		return filepath:sub(#cached + 2), dir
	end
	return nil, nil
end

--- Read file contents from disk via libuv
---@param filepath string
---@return string|nil data, nil on failure
function M.read_file(filepath)
	local fd = vim.uv.fs_open(filepath, "r", M.FILE_MODE)
	if not fd then return nil end
	local stat = vim.uv.fs_fstat(fd)
	if not stat or stat.size == 0 then
		vim.uv.fs_close(fd)
		return stat and "" or nil
	end
	local data = vim.uv.fs_read(fd, stat.size, 0)
	vim.uv.fs_close(fd)
	return data
end

--- Get the "before" text for a file (git HEAD, snapshot fallback)
---@param filepath string absolute path
---@param cwd string|nil
---@param current_text string|nil current file content for snapshot comparison
---@return string old text (may be empty)
function M.get_old_text(filepath, cwd, current_text)
	-- Always prefer git HEAD — snapshots are taken on BufReadPost which is
	-- typically after Claude has already edited the file (post-edit content).
	local git_rel, git_dir = M.git_relpath(filepath)
	if git_rel and git_rel:find("%.%.") == nil then
		local cached = git_show_cache[git_rel]
		if cached then return cached end
		local cmd = "git show HEAD:" .. vim.fn.shellescape(git_rel) .. " 2>/dev/null"
		if git_dir then cmd = "git -C " .. vim.fn.shellescape(git_dir) .. " show HEAD:" .. vim.fn.shellescape(git_rel) .. " 2>/dev/null" end
		local lines = vim.fn.systemlist(cmd)
		if vim.v.shell_error == 0 and #lines > 0 then
			local result = table.concat(lines, "\n") .. "\n"
			git_show_cache[git_rel] = result
			return result
		end
	end

	-- Fallback to snapshot (for new untracked files)
	local snapshots = require("cc-watcher.snapshots")
	local snap = snapshots.get(filepath)
	if snap and snap.raw ~= "" then
		if not current_text or snap.raw ~= current_text then
			return snap.raw
		end
	end
	return ""
end

--- Compute hunk indices between old and new text (with trailing newline normalization)
---@param old_text string
---@param new_text string
---@return table|nil hunks array of {old_start, old_count, new_start, new_count}
function M.compute_hunks(old_text, new_text)
	if old_text == "" and new_text == "" then return nil end
	if old_text ~= "" and old_text:sub(-1) ~= "\n" then old_text = old_text .. "\n" end
	if new_text ~= "" and new_text:sub(-1) ~= "\n" then new_text = new_text .. "\n" end
	return vim.diff(old_text, new_text, { result_type = "indices", algorithm = "histogram" })
end

--- Compute unified diff string
---@param old_text string
---@param new_text string
---@return string|nil
function M.compute_unified(old_text, new_text)
	if old_text == "" and new_text == "" then return nil end
	return vim.diff(old_text, new_text, { result_type = "unified", ctxlen = 3 })
end

--- Compute add/del stats from hunks
---@param hunks table
---@return number additions, number deletions
function M.hunk_stats(hunks)
	local add, del = 0, 0
	for _, h in ipairs(hunks) do
		add = add + h[4]
		del = del + h[2]
	end
	return add, del
end

--- Collect all changed files (watcher + session), async
---@param callback fun(files: { abs: string, rel: string, live: boolean }[], cwd: string)
function M.collect_files(callback)
	local watcher = require("cc-watcher.watcher")
	local session = require("cc-watcher.session")
	local cwd = vim.uv.cwd()
	local files = {}
	local seen = {}

	for filepath in pairs(watcher.get_changed_files()) do
		seen[filepath] = true
		files[#files + 1] = { abs = filepath, rel = M.relpath(filepath, cwd), live = true }
	end

	session.get_claude_edited_files_async(function(session_files)
		for _, filepath in ipairs(session_files or {}) do
			if not seen[filepath] then
				-- Only include session files that actually differ from git HEAD
				local old_text = M.get_old_text(filepath, cwd)
				local new_text = M.read_file(filepath) or ""
				local hunks = M.compute_hunks(old_text, new_text)
				if hunks and #hunks > 0 then
					seen[filepath] = true
					files[#files + 1] = { abs = filepath, rel = M.relpath(filepath, cwd), live = false }
				end
			end
		end
		table.sort(files, function(a, b) return a.rel < b.rel end)
		callback(files, cwd)
	end, cwd)
end

return M
