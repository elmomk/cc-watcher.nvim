-- session.lua — Read Claude Code session data to find which files were edited
-- Parses ~/.claude/ session JSONL files. Caches results.

local M = {}

local sessions_dir = vim.fn.expand("~/.claude/sessions")
local projects_dir = vim.fn.expand("~/.claude/projects")

local cache = { jsonl_path = nil, mtime = 0, files = {} }
local jsonl_cache = { cwd = nil, path = nil, checked_at = 0 }

---@param cwd string
---@return { pid: number, sessionId: string, cwd: string }|nil
function M.find_active_session(cwd)
	local handle = vim.uv.fs_scandir(sessions_dir)
	if not handle then return nil end

	local best = nil
	while true do
		local name, typ = vim.uv.fs_scandir_next(handle)
		if not name then break end
		if typ == "file" and name:match("%.json$") then
			local path = sessions_dir .. "/" .. name
			local fd = vim.uv.fs_open(path, "r", 438)
			if fd then
				local stat = vim.uv.fs_stat(path)
				if stat then
					local data = vim.uv.fs_read(fd, stat.size, 0)
					vim.uv.fs_close(fd)
					if data then
						local ok, sess = pcall(vim.fn.json_decode, data)
						if ok and sess and sess.cwd == cwd and sess.pid then
							local pid = tonumber(sess.pid)
							if pid and pid > 0 and vim.uv.kill(pid, 0) == 0 then
								if not best or (sess.startedAt or 0) > (best.startedAt or 0) then
									best = sess
								end
							end
						end
					end
				else
					vim.uv.fs_close(fd)
				end
			end
		end
	end
	return best
end

---@param cwd string
---@return string|nil
function M.find_latest_jsonl(cwd)
	-- Cache: re-scan at most every 5 seconds
	local now = vim.uv.now() / 1000
	if jsonl_cache.cwd == cwd and jsonl_cache.path and (now - jsonl_cache.checked_at) < 5 then
		return jsonl_cache.path
	end

	local handle = vim.uv.fs_scandir(projects_dir)
	if not handle then return nil end

	local best_path, best_mtime = nil, 0
	while true do
		local name, typ = vim.uv.fs_scandir_next(handle)
		if not name then break end
		if typ == "directory" then
			local dir_path = projects_dir .. "/" .. name
			local dir_handle = vim.uv.fs_scandir(dir_path)
			if dir_handle then
				while true do
					local fname, ftyp = vim.uv.fs_scandir_next(dir_handle)
					if not fname then break end
					if ftyp == "file" and fname:match("%.jsonl$") then
						local fpath = dir_path .. "/" .. fname
						local stat = vim.uv.fs_stat(fpath)
						if stat and stat.mtime.sec > best_mtime then
							local fd = vim.uv.fs_open(fpath, "r", 438)
							if fd then
								local chunk = vim.uv.fs_read(fd, 4096, 0)
								vim.uv.fs_close(fd)
								if chunk then
									local line = chunk:match("^[^\n]+")
									if line and line:find(cwd, 1, true) then
										best_path = fpath
										best_mtime = stat.mtime.sec
									end
								end
							end
						end
					end
				end
			end
		end
	end
	jsonl_cache.cwd = cwd
	jsonl_cache.path = best_path
	jsonl_cache.checked_at = now
	return best_path
end

--- Parse matching lines from grep output using Lua's json decoder
---@param grep_lines string[]
---@return string[]
local function parse_grep_output(grep_lines)
	local seen = {}
	local files = {}

	for _, line in ipairs(grep_lines) do
		if line == "" then goto continue end
		local ok, entry = pcall(vim.fn.json_decode, line)
		if not ok or not entry then goto continue end

		local msg = entry.message
		if not msg then goto continue end
		local content = msg.content
		if type(content) ~= "table" then goto continue end

		for _, block in ipairs(content) do
			if type(block) == "table" and block.type == "tool_use" then
				local name = block.name
				local inp = block.input
				if (name == "Write" or name == "Edit") and inp and inp.file_path then
					local fp = inp.file_path
					if not seen[fp] then
						seen[fp] = true
						table.insert(files, fp)
					end
				end
			end
		end
		::continue::
	end

	return files
end

---@param jsonl_path string
---@param callback fun(files: string[])
function M.get_edited_files_async(jsonl_path, callback)
	-- Use grep to filter to only Write/Edit lines, then parse in Lua
	-- This avoids the python3 dependency entirely
	local output = {}
	local job_id = vim.fn.jobstart(
		{ "grep", "-E", '"name":"(Write|Edit)"', jsonl_path },
		{
			stdout_buffered = true,
			on_stdout = function(_, data)
				for _, line in ipairs(data) do
					if line ~= "" then table.insert(output, line) end
				end
			end,
			on_exit = function()
				local files = parse_grep_output(output)
				callback(files)
			end,
		}
	)
	if job_id <= 0 then
		callback({})
	end
end

---@param callback fun(files: string[])
---@param cwd string|nil
function M.get_claude_edited_files_async(callback, cwd)
	cwd = cwd or vim.fn.getcwd()

	local jsonl_path = M.find_latest_jsonl(cwd)
	if not jsonl_path then
		callback({})
		return
	end

	local stat = vim.uv.fs_stat(jsonl_path)
	if stat and jsonl_path == cache.jsonl_path and stat.mtime.sec == cache.mtime then
		callback(cache.files)
		return
	end

	M.get_edited_files_async(jsonl_path, function(files)
		cache.jsonl_path = jsonl_path
		cache.mtime = stat and stat.mtime.sec or 0
		cache.files = files
		callback(files)
	end)
end

return M
