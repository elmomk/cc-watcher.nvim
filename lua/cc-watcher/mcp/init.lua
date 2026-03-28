-- mcp/init.lua — MCP WebSocket bridge orchestrator
-- Manages server lifecycle, lock file, selection tracking, and cleanup.

local M = {}

local server = require("cc-watcher.mcp.server")
local lockfile = require("cc-watcher.mcp.lockfile")
local sel = require("cc-watcher.mcp.selection")

local active_port = nil
local active_token = nil
local autocmd_group = nil
local config = {}

--- Start the MCP bridge
---@return boolean success
---@return string|nil error
local function start()
	if server.is_running() then
		return true
	end

	-- Configure server
	server.configure({
		port_range = config.port_range,
		max_connections = config.max_connections,
		max_send_queue = config.max_send_queue,
		ping_interval_ms = config.ping_interval_ms,
		diff_timeout_ms = config.diff_timeout_ms,
	})

	-- Start TCP server
	local port, err = server.start(config.port_range)
	if not port then
		vim.notify("[cc-watcher/mcp] failed to start: " .. (err or "unknown"), vim.log.levels.ERROR)
		return false, err
	end

	-- Write lock file
	local lock_path, token, lock_err = lockfile.write(port, config.ide_name)
	if not lock_path then
		server.stop()
		vim.notify("[cc-watcher/mcp] lock file error: " .. (lock_err or "unknown"), vim.log.levels.ERROR)
		return false, lock_err
	end

	-- Set auth token
	server.set_auth_token(token)
	active_port = port
	active_token = token

	-- Start selection tracking
	if config.selection_tracking then
		sel.setup({
			debounce_ms = config.selection_debounce_ms,
			on_change = function(selection)
				if server.is_running() then
					server.broadcast("notifications/selectionChanged", selection)
				end
			end,
		})
	end

	vim.notify("[cc-watcher/mcp] listening on 127.0.0.1:" .. port, vim.log.levels.INFO)
	return true
end

--- Stop the MCP bridge
local function stop()
	sel.shutdown()
	server.stop()
	lockfile.remove()
	active_port = nil
	active_token = nil
end

--- Set up the MCP bridge
---@param opts table MCP config from cc-watcher setup
function M.setup(opts)
	config = vim.tbl_deep_extend("force", {
		enabled = false,
		auto_start = true,
		port_range = { 10000, 65535 },
		ide_name = "Neovim",
		selection_tracking = true,
		diff_timeout_ms = 300000,
		ping_interval_ms = 30000,
		selection_debounce_ms = 100,
		max_connections = 2,
		max_send_queue = 1000,
	}, opts or {})

	-- Set up autocmds
	if autocmd_group then
		vim.api.nvim_del_augroup_by_id(autocmd_group)
	end
	autocmd_group = vim.api.nvim_create_augroup("CcWatcherMcp", { clear = true })

	-- Graceful shutdown
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = autocmd_group,
		callback = function()
			stop()
		end,
	})

	-- Update lock file workspace folders on tab changes
	vim.api.nvim_create_autocmd({ "TabEnter", "TabClosed" }, {
		group = autocmd_group,
		callback = function()
			if active_port and active_token then
				lockfile.update_workspaces(active_port, active_token, config.ide_name)
			end
		end,
	})

	-- Auto-start if configured
	if config.auto_start then
		-- Defer slightly to let Neovim finish initializing
		vim.schedule(function()
			start()
		end)
	end
end

--- Shut down the MCP bridge and clean up
function M.shutdown()
	stop()
	if autocmd_group then
		vim.api.nvim_del_augroup_by_id(autocmd_group)
		autocmd_group = nil
	end
end

--- Start the MCP bridge (for manual :ClaudeMcp start)
---@return boolean success
---@return string|nil error
function M.start()
	return start()
end

--- Stop the MCP bridge (for manual :ClaudeMcp stop)
function M.stop()
	stop()
end

--- Check if the MCP bridge is running
---@return boolean
function M.is_running()
	return server.is_running()
end

--- Get status info
---@return table
function M.status()
	local s = server.status()
	s.port = active_port
	s.lock_file = lockfile.get_path()
	return s
end

return M
