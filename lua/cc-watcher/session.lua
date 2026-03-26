-- session.lua — Read Claude Code session data
-- Incremental tail-read of JSONL (only parses new bytes).
-- Pure Lua: no python3 or grep subprocess.
-- fs_event on JSONL for event-driven sidebar updates.

local M = {}

local sessions_dir = vim.fn.expand("~/.claude/sessions")
local projects_dir = vim.fn.expand("~/.claude/projects")

local jsonl_dir_cache = { cwd = nil, paths = nil, checked_at = 0 }
local active_session_cache = { cwd = nil, result = nil, checked_at = 0 }

-- Incremental parse state per JSONL file
local tails = {} -- jsonl_path -> { offset, seen, files }
-- Merged result across all JSONL files
local merged = { cwd = nil, seen = {}, files = {} }

--- Reset internal state (for testing)
function M._reset()
	tails = {}
	merged = { cwd = nil, seen = {}, files = {} }
	jsonl_dir_cache.cwd = nil
	jsonl_dir_cache.paths = nil
	jsonl_dir_cache.checked_at = 0
	active_session_cache.cwd = nil
	active_session_cache.result = nil
	active_session_cache.checked_at = 0
end

-- JSONL file watcher
local jsonl_watcher_handle = nil
local jsonl_change_callbacks = {}

function M.invalidate_session_cache()
	active_session_cache.checked_at = 0
end

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
	if active_session_cache.cwd == cwd and (now - active_session_cache.checked_at) < 30 then
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

--- Find ALL JSONL files for a project (all sessions)
---@param cwd string
---@return string[] paths (newest first)
function M.find_all_jsonl(cwd)
	local now = vim.uv.now() / 1000
	if jsonl_dir_cache.cwd == cwd and jsonl_dir_cache.paths and (now - jsonl_dir_cache.checked_at) < 5 then
		return jsonl_dir_cache.paths
	end

	-- Claude Code encodes project path: /home/user/my_project → -home-user-my-project
	-- Both / and _ are replaced with -
	local encoded = cwd:gsub("[/_]", "-")
	local project_dir = projects_dir .. "/" .. encoded

	local handle = vim.uv.fs_scandir(project_dir)
	if not handle then
		jsonl_dir_cache.cwd = cwd
		jsonl_dir_cache.paths = {}
		jsonl_dir_cache.checked_at = now
		return {}
	end

	local entries = {}
	while true do
		local name, typ = vim.uv.fs_scandir_next(handle)
		if not name then break end
		if typ == "file" and name:match("%.jsonl$") then
			local fpath = project_dir .. "/" .. name
			local stat = vim.uv.fs_stat(fpath)
			if stat then
				entries[#entries + 1] = { path = fpath, mtime = stat.mtime.sec }
			end
		end
	end

	-- Sort newest first
	table.sort(entries, function(a, b) return a.mtime > b.mtime end)

	local paths = {}
	for _, e in ipairs(entries) do paths[#paths + 1] = e.path end

	jsonl_dir_cache.cwd = cwd
	jsonl_dir_cache.paths = paths
	jsonl_dir_cache.checked_at = now
	return paths
end

--- Backward-compatible: return the latest JSONL path
---@param cwd string
---@return string|nil
function M.find_latest_jsonl(cwd)
	local paths = M.find_all_jsonl(cwd)
	return paths[1]
end

--- Incremental read of a single JSONL file (only new bytes since last parse)
---@param jsonl_path string
---@param seen table<string, true> shared dedup set (mutated)
---@param files string[] shared output list (mutated)
local function read_jsonl_incremental(jsonl_path, seen, files)
	local stat = vim.uv.fs_stat(jsonl_path)
	if not stat then return end

	local t = tails[jsonl_path]
	if not t or stat.size < t.offset then
		t = { offset = 0 }
		tails[jsonl_path] = t
	end

	if stat.size == t.offset then return end

	local bytes_to_read = stat.size - t.offset
	local fd = vim.uv.fs_open(jsonl_path, "r", 438)
	if not fd then return end

	local data = vim.uv.fs_read(fd, bytes_to_read, t.offset)
	vim.uv.fs_close(fd)

	if data and #data > 0 then
		parse_chunk(data, seen, files)
		t.offset = stat.size
	end
end

--- Read a single JSONL file with persistent incremental state (backward compat)
---@param jsonl_path string
---@param callback fun(files: string[])
function M.get_edited_files_async(jsonl_path, callback)
	local t = tails[jsonl_path]
	if not t then
		t = { offset = 0, seen = {}, files = {} }
		tails[jsonl_path] = t
	end
	-- Ensure per-path seen/files exist (read_jsonl_incremental uses shared tables,
	-- but for direct single-file calls we use per-tail storage)
	if not t.seen then t.seen = {} end
	if not t.files then t.files = {} end

	local stat = vim.uv.fs_stat(jsonl_path)
	if not stat then callback(t.files or {}); return end
	if stat.size < t.offset then
		t = { offset = 0, seen = {}, files = {} }
		tails[jsonl_path] = t
	end
	if stat.size == t.offset then callback(t.files); return end

	local bytes = stat.size - t.offset
	local fd = vim.uv.fs_open(jsonl_path, "r", 438)
	if not fd then callback(t.files); return end
	local data = vim.uv.fs_read(fd, bytes, t.offset)
	vim.uv.fs_close(fd)

	if data and #data > 0 then
		parse_chunk(data, t.seen, t.files)
		t.offset = stat.size
	end
	callback(t.files)
end

---@param callback fun(files: string[])
---@param cwd string|nil
function M.get_claude_edited_files_async(callback, cwd)
	cwd = cwd or vim.uv.cwd()

	local paths = M.find_all_jsonl(cwd)
	if #paths == 0 then
		callback({})
		return
	end

	-- Reset merged state if cwd changed
	if merged.cwd ~= cwd then
		merged = { cwd = cwd, seen = {}, files = {} }
		tails = {}
	end

	-- Parse all JSONL files incrementally into the shared merged set
	for _, jsonl_path in ipairs(paths) do
		read_jsonl_incremental(jsonl_path, merged.seen, merged.files)
	end

	-- Filter to files inside the project directory, excluding .git/ and .claude/
	local cwd_prefix = cwd .. "/"
	local filtered = {}
	for _, fp in ipairs(merged.files) do
		if fp:sub(1, #cwd_prefix) == cwd_prefix then
			local rel = fp:sub(#cwd_prefix + 1)
			if not rel:match("^%.git/") and not rel:match("^%.claude/") then
				filtered[#filtered + 1] = fp
			end
		end
	end

	callback(filtered)
end

--- Start watching the active JSONL file for changes
---@param cwd string|nil
function M.watch_jsonl(cwd)
	if jsonl_watcher_handle then
		jsonl_watcher_handle:stop()
		jsonl_watcher_handle:close()
		jsonl_watcher_handle = nil
	end

	cwd = cwd or vim.uv.cwd()
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
			active_session_cache.checked_at = 0  -- force re-check on next render
			for _, cb in ipairs(jsonl_change_callbacks) do
				pcall(cb, path)
			end
		end
	end))
end

return M
