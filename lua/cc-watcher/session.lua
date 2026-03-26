-- session.lua — Read Claude Code session data
-- Incremental tail-read of JSONL (only parses new bytes).
-- Pure Lua: no python3 or grep subprocess.
-- fs_event on JSONL for event-driven sidebar updates.

local M = {}

local sessions_dir = vim.fn.expand("~/.claude/sessions")
local projects_dir = vim.fn.expand("~/.claude/projects")

local jsonl_dir_cache = { cwd = nil, path = nil, checked_at = 0 }
local active_session_cache = { cwd = nil, result = nil, checked_at = 0 }

-- Incremental parse state
local tail = {
	jsonl_path = nil,
	offset = 0,
	seen = {},
	files = {},
}

--- Reset internal state (for testing)
function M._reset()
	tail.jsonl_path = nil
	tail.offset = 0
	tail.seen = {}
	tail.files = {}
	jsonl_dir_cache.cwd = nil
	jsonl_dir_cache.path = nil
	jsonl_dir_cache.checked_at = 0
	active_session_cache.cwd = nil
	active_session_cache.result = nil
	active_session_cache.checked_at = 0
end

-- JSONL file watcher
local jsonl_watcher_handle = nil
local jsonl_change_callbacks = {}

---@param cb fun(path: string)
function M.on_jsonl_change(cb)
	jsonl_change_callbacks[#jsonl_change_callbacks + 1] = cb
end

--- Extract Write/Edit file_path entries from JSONL lines (pure Lua)
---@param data string raw JSONL text
---@param seen table<string, true> dedup set (mutated)
---@param files string[] output list (mutated)
local function parse_chunk(data, seen, files)
	for line in data:gmatch("[^\n]+") do
		-- Fast pre-filter: skip lines without Write/Edit
		if line:find('"name":"Write"', 1, true)
			or line:find('"name":"Edit"', 1, true) then
			local ok, entry = pcall(vim.json.decode, line)
			if ok and entry then
				local msg = entry.message
				if msg and type(msg.content) == "table" then
					for _, block in ipairs(msg.content) do
						if type(block) == "table" and block.type == "tool_use"
							and (block.name == "Write" or block.name == "Edit")
							and block.input and block.input.file_path then
							local fp = block.input.file_path
							-- Reject paths with traversal or outside project
							if fp and not fp:find("%.%./") and fp:sub(1, 1) == "/" then
								if not seen[fp] then
									seen[fp] = true
									files[#files + 1] = fp
								end
							end
						end
					end
				end
			end
		end
	end
end

---@param cwd string
---@return { pid: number, sessionId: string, cwd: string }|nil
function M.find_active_session(cwd)
	local now = vim.uv.now() / 1000
	if active_session_cache.cwd == cwd and (now - active_session_cache.checked_at) < 5 then
		return active_session_cache.result
	end

	local handle = vim.uv.fs_scandir(sessions_dir)
	if not handle then
		active_session_cache.cwd = cwd
		active_session_cache.result = nil
		active_session_cache.checked_at = now
		return nil
	end

	local best = nil
	while true do
		local name, typ = vim.uv.fs_scandir_next(handle)
		if not name then break end
		if typ == "file" and name:match("%.json$") then
			local path = sessions_dir .. "/" .. name
			local fd = vim.uv.fs_open(path, "r", 438)
			if fd then
				local stat = vim.uv.fs_fstat(fd)
				if stat and stat.size < 1048576 then
					local data = vim.uv.fs_read(fd, stat.size, 0)
					vim.uv.fs_close(fd)
					if data then
						local ok, sess = pcall(vim.json.decode, data)
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

	active_session_cache.cwd = cwd
	active_session_cache.result = best
	active_session_cache.checked_at = now
	return best
end

---@param cwd string
---@return string|nil
function M.find_latest_jsonl(cwd)
	local now = vim.uv.now() / 1000
	if jsonl_dir_cache.cwd == cwd and jsonl_dir_cache.path and (now - jsonl_dir_cache.checked_at) < 5 then
		return jsonl_dir_cache.path
	end

	-- Claude Code encodes project path: /home/user/project → -home-user-project
	local encoded = cwd:gsub("/", "-")
	local project_dir = projects_dir .. "/" .. encoded

	local handle = vim.uv.fs_scandir(project_dir)
	if not handle then
		-- Cache negative result too
		jsonl_dir_cache.cwd = cwd
		jsonl_dir_cache.path = nil
		jsonl_dir_cache.checked_at = now
		return nil
	end

	local best_path, best_mtime = nil, 0
	while true do
		local name, typ = vim.uv.fs_scandir_next(handle)
		if not name then break end
		if typ == "file" and name:match("%.jsonl$") then
			local fpath = project_dir .. "/" .. name
			local stat = vim.uv.fs_stat(fpath)
			if stat and stat.mtime.sec > best_mtime then
				best_path = fpath
				best_mtime = stat.mtime.sec
			end
		end
	end

	jsonl_dir_cache.cwd = cwd
	jsonl_dir_cache.path = best_path
	jsonl_dir_cache.checked_at = now
	return best_path
end

--- Incremental async read: only reads new bytes since last parse
---@param jsonl_path string
---@param callback fun(files: string[])
function M.get_edited_files_async(jsonl_path, callback)
	-- Reset if different file or file was truncated
	local stat = vim.uv.fs_stat(jsonl_path)
	if not stat then
		callback({})
		return
	end

	if jsonl_path ~= tail.jsonl_path or stat.size < tail.offset then
		tail = { jsonl_path = jsonl_path, offset = 0, seen = {}, files = {} }
	end

	-- Nothing new
	if stat.size == tail.offset then
		callback(tail.files)
		return
	end

	local bytes_to_read = stat.size - tail.offset
	local fd = vim.uv.fs_open(jsonl_path, "r", 438)
	if not fd then
		callback(tail.files)
		return
	end

	local data = vim.uv.fs_read(fd, bytes_to_read, tail.offset)
	vim.uv.fs_close(fd)

	if data and #data > 0 then
		parse_chunk(data, tail.seen, tail.files)
		tail.offset = stat.size
	end

	callback(tail.files)
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

	M.get_edited_files_async(jsonl_path, callback)
end

--- Start watching the active JSONL file for changes
---@param cwd string|nil
function M.watch_jsonl(cwd)
	if jsonl_watcher_handle then
		jsonl_watcher_handle:stop()
		jsonl_watcher_handle:close()
		jsonl_watcher_handle = nil
	end

	cwd = cwd or vim.fn.getcwd()
	local path = M.find_latest_jsonl(cwd)
	if not path then return end

	jsonl_watcher_handle = vim.uv.new_fs_event()
	if not jsonl_watcher_handle then return end

	jsonl_watcher_handle:start(path, {}, vim.schedule_wrap(function(err, _, events)
		if err then return end
		if events and events.rename then
			-- File replaced; re-watch after delay
			vim.defer_fn(function() M.watch_jsonl(cwd) end, 200)
			return
		end
		if events and events.change then
			for _, cb in ipairs(jsonl_change_callbacks) do
				pcall(cb, path)
			end
		end
	end))
end

return M
