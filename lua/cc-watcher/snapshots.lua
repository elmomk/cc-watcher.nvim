-- snapshots.lua — Track file contents as nvim sees them
-- LRU eviction via generation counter. Stores raw string for O(1) comparison.

local M = {}

local store = {}
local store_count = 0
local MAX_FILE_SIZE = 10 * 1024 * 1024 -- 10 MB
local MAX_SNAPSHOTS = 100
local generation = 0

local function touch(filepath)
	generation = generation + 1
	if store[filepath] then
		store[filepath]._gen = generation
	end
end

local function evict_oldest()
	while store_count > MAX_SNAPSHOTS do
		local min_gen, min_key = math.huge, nil
		for k, v in pairs(store) do
			if v._gen < min_gen then min_gen = v._gen; min_key = k end
		end
		if min_key then store[min_key] = nil; store_count = store_count - 1
		else break end
	end
end

---@param filepath string absolute path
function M.take(filepath)
	local fd = vim.uv.fs_open(filepath, "r", require("cc-watcher.util").READ_MODE)
	if not fd then return end
	local stat = vim.uv.fs_fstat(fd)
	if not stat or stat.size > MAX_FILE_SIZE then
		vim.uv.fs_close(fd)
		return
	end
	local data = vim.uv.fs_read(fd, stat.size, 0)
	vim.uv.fs_close(fd)

	if data then
		local is_new = store[filepath] == nil
		generation = generation + 1
		store[filepath] = {
			raw = data,
			mtime = stat.mtime.sec,
			_gen = generation,
		}
		if is_new then store_count = store_count + 1 end
		evict_oldest()
	end
end

---@return { raw: string, mtime: number }|nil
function M.get(filepath)
	local snap = store[filepath]
	if snap then touch(filepath) end
	return snap
end

function M.has(filepath)
	return store[filepath] ~= nil
end

function M.remove(filepath)
	if store[filepath] then store_count = store_count - 1 end
	store[filepath] = nil
end

function M.clear()
	store = {}
	store_count = 0
	generation = 0
end

function M.count()
	return store_count
end

return M
