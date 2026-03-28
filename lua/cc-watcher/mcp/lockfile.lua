-- lockfile.lua — IDE lock file management for Claude Code discovery
-- Writes/removes ~/.claude/ide/<port>.lock with connection details.

local M = {}

local uv = vim.uv
local lock_path = nil -- active lock file path

--- Generate a cryptographically strong auth token
---@return string base64-encoded token
local function generate_token()
	local raw = uv.random(48)
	return require("cc-watcher.mcp.crypto").base64_encode(raw)
end

--- Get git root for a directory, or nil
---@param dir string
---@return string|nil
local function git_root(dir)
	local out = vim.fn.systemlist("git -C " .. vim.fn.shellescape(dir) .. " rev-parse --show-toplevel 2>/dev/null")
	if vim.v.shell_error == 0 and out[1] and out[1] ~= "" then
		return out[1]
	end
	return nil
end

--- Gather workspace folders from all tabpages (lcd / git roots)
---@return table[] array of { name, uri, path }
function M.get_workspace_folders()
	local seen = {}
	local folders = {}

	-- Collect from tabpages
	for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
		local dir = vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(tabpage))
		if not dir or dir == "" then
			dir = uv.cwd()
		end

		local root = git_root(dir) or dir
		if root and not seen[root] then
			seen[root] = true
			folders[#folders + 1] = root
		end
	end

	-- Always include cwd
	local cwd = uv.cwd()
	local cwd_root = git_root(cwd) or cwd
	if not seen[cwd_root] then
		seen[cwd_root] = true
		folders[#folders + 1] = cwd_root
	end

	return folders
end

--- Write lock file for Claude CLI discovery
---@param port number server port
---@param ide_name string IDE display name
---@return string|nil lock_path, string|nil auth_token, string|nil error
function M.write(port, ide_name)
	local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "/tmp"
	local ide_dir = home .. "/.claude/ide"

	-- Ensure directory exists
	local stat = uv.fs_stat(ide_dir)
	if not stat then
		-- Create ~/.claude if needed
		local claude_dir = home .. "/.claude"
		if not uv.fs_stat(claude_dir) then
			local ok, err = uv.fs_mkdir(claude_dir, 448) -- 0700
			if not ok then
				return nil, nil, "mkdir ~/.claude failed: " .. tostring(err)
			end
		end
		local ok, err = uv.fs_mkdir(ide_dir, 448) -- 0700
		if not ok then
			return nil, nil, "mkdir ~/.claude/ide failed: " .. tostring(err)
		end
	end

	local token = generate_token()
	local folders = M.get_workspace_folders()

	local data = vim.json.encode({
		pid = uv.os_getpid(),
		workspaceFolders = folders,
		ideName = ide_name,
		transport = "ws",
		authToken = token,
	})

	local path = ide_dir .. "/" .. port .. ".lock"
	local fd, err = uv.fs_open(path, "w", 384) -- 0600
	if not fd then
		return nil, nil, "open lock file failed: " .. tostring(err)
	end
	uv.fs_write(fd, data, 0)
	uv.fs_close(fd)

	lock_path = path

	-- Set environment variables for Claude CLI subprocess discovery
	vim.env.CLAUDE_CODE_SSE_PORT = tostring(port)
	vim.env.ENABLE_IDE_INTEGRATION = "1"

	return path, token, nil
end

--- Update workspace folders in the lock file (called on tab changes)
---@param port number server port
---@param token string auth token
---@param ide_name string IDE display name
function M.update_workspaces(port, token, ide_name)
	if not lock_path then return end

	local folders = M.get_workspace_folders()
	local data = vim.json.encode({
		pid = uv.os_getpid(),
		workspaceFolders = folders,
		ideName = ide_name,
		transport = "ws",
		authToken = token,
	})

	local fd = uv.fs_open(lock_path, "w", 384)
	if fd then
		uv.fs_write(fd, data, 0)
		uv.fs_close(fd)
	end
end

--- Remove lock file and clear env vars
function M.remove()
	if lock_path then
		uv.fs_unlink(lock_path)
		lock_path = nil
	end
	vim.env.CLAUDE_CODE_SSE_PORT = nil
	vim.env.ENABLE_IDE_INTEGRATION = nil
end

--- Get current lock file path
---@return string|nil
function M.get_path()
	return lock_path
end

return M
