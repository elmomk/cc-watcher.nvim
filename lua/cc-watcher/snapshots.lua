-- snapshots.lua — Track file contents as nvim sees them

local M = {}

-- filepath -> { lines = string[], mtime = number }
local store = {}

local MAX_FILE_SIZE = 10 * 1024 * 1024 -- 10 MB

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
			mtime = stat.mtime.sec,
		}
	end
end

---@param filepath string
---@return { lines: string[], mtime: number }|nil
function M.get(filepath)
	return store[filepath]
end

---@param filepath string
---@return boolean
function M.has(filepath)
	return store[filepath] ~= nil
end

---@param filepath string
function M.remove(filepath)
	store[filepath] = nil
end

function M.clear()
	store = {}
end

return M
