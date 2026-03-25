-- snapshots.lua — Track file contents as nvim sees them
-- LRU eviction to cap memory. Stores raw string for fast comparison.

local M = {}

local store = {}
local MAX_FILE_SIZE = 10 * 1024 * 1024 -- 10 MB
local MAX_SNAPSHOTS = 100
local access_order = {}

local function touch(filepath)
	for i, fp in ipairs(access_order) do
		if fp == filepath then
			table.remove(access_order, i)
			break
		end
	end
	access_order[#access_order + 1] = filepath
end

local function evict_oldest()
	while #access_order > MAX_SNAPSHOTS do
		local oldest = table.remove(access_order, 1)
		store[oldest] = nil
	end
end

---@param filepath string absolute path
function M.take(filepath)
	local stat = vim.uv.fs_stat(filepath)
	if not stat or stat.size > MAX_FILE_SIZE then return end

	local fd = vim.uv.fs_open(filepath, "r", 438)
	if not fd then return end
	local data = vim.uv.fs_read(fd, stat.size, 0)
	vim.uv.fs_close(fd)

	if data then
		store[filepath] = {
			lines = vim.split(data, "\n", { plain = true }),
			raw = data,
			mtime = stat.mtime.sec,
		}
		touch(filepath)
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
	for i, fp in ipairs(access_order) do
		if fp == filepath then
			table.remove(access_order, i)
			break
		end
	end
end

function M.clear()
	store = {}
	access_order = {}
end

function M.count()
	return #access_order
end

return M
