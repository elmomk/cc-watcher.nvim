-- snapshots.lua — Track file contents as nvim sees them
-- LRU eviction via generation counter. Stores raw string for O(1) comparison.

local M = {}

local store = {}
local MAX_FILE_SIZE = 10 * 1024 * 1024 -- 10 MB
local MAX_SNAPSHOTS = 100
local generation = 0

local SPLIT_OPTS = { plain = true }

local function touch(filepath)
	generation = generation + 1
	if store[filepath] then
		store[filepath]._gen = generation
	end
end

local function evict_oldest()
	local count = 0
	for _ in pairs(store) do count = count + 1 end
	while count > MAX_SNAPSHOTS do
		local min_gen, min_key = math.huge, nil
		for k, v in pairs(store) do
			if v._gen < min_gen then min_gen = v._gen; min_key = k end
		end
		if min_key then store[min_key] = nil; count = count - 1
		else break end
	end
end

---@param filepath string absolute path
function M.take(filepath)
	local fd = vim.uv.fs_open(filepath, "r", 438)
	if not fd then return end
	local stat = vim.uv.fs_fstat(fd)
	if not stat or stat.size > MAX_FILE_SIZE then
		vim.uv.fs_close(fd)
		return
	end
	local data = vim.uv.fs_read(fd, stat.size, 0)
	vim.uv.fs_close(fd)

	if data then
		generation = generation + 1
		store[filepath] = {
			lines = vim.split(data, "\n", SPLIT_OPTS),
			raw = data,
			mtime = stat.mtime.sec,
			_gen = generation,
		}
		evict_oldest()
	end
end

---@return { lines: string[], raw: string, mtime: number }|nil
function M.get(filepath)
	local snap = store[filepath]
	if snap then touch(filepath) end
	return snap
end

function M.has(filepath)
	return store[filepath] ~= nil
end

function M.remove(filepath)
	store[filepath] = nil
end

function M.clear()
	store = {}
	generation = 0
end

function M.count()
	local n = 0
	for _ in pairs(store) do n = n + 1 end
	return n
end

return M
