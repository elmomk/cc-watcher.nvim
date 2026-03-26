-- watcher.lua — Watch for file changes Claude Code makes
-- Per-file fs_event watchers. Handles delete/rename/wipeout cleanup.

local M = {}

local snapshots = require("cc-watcher.snapshots")

local augroup = vim.api.nvim_create_augroup("ClaudeCodeWatcher", { clear = true })

local file_watchers = {}
local changed_files = {}
local on_change_callbacks = {}

---@param cb fun(filepath: string, relpath: string)
function M.on_change(cb)
	on_change_callbacks[#on_change_callbacks + 1] = cb
end

function M.get_changed_files()
	return changed_files
end

function M.mark_changed(filepath)
	if changed_files[filepath] then return end

	local cwd = vim.uv.cwd()
	local relpath = filepath
	if filepath:sub(1, #cwd) == cwd then
		relpath = filepath:sub(#cwd + 2)
	end

	changed_files[filepath] = true

	for _, cb in ipairs(on_change_callbacks) do
		pcall(cb, filepath, relpath)
	end
end

function M.should_ignore(path)
	return path:match("/%.git/") ~= nil
		or path:match("/%.claude/") ~= nil
		or path:find("/node_modules/", 1, true) ~= nil
		or path:find("/target/", 1, true) ~= nil
		or path:match("%.swp$") ~= nil
		or path:sub(-1) == "~"
end

local function unwatch_file(filepath)
	local h = file_watchers[filepath]
	if h then
		h:stop()
		h:close()
		file_watchers[filepath] = nil
	end
end

local function watch_file(filepath)
	if file_watchers[filepath] or M.should_ignore(filepath) then return end

	local handle = vim.uv.new_fs_event()
	if not handle then return end

	handle:start(filepath, {}, vim.schedule_wrap(function(err, _, events)
		if err then
			unwatch_file(filepath)
			return
		end
		-- File deleted or renamed — clean up watcher
		if events and events.rename then
			unwatch_file(filepath)
			return
		end
		if not events or not events.change then return end

		local snap = snapshots.get(filepath)
		if not snap then return end

		-- Use fstat on open fd to avoid TOCTOU
		local fd = vim.uv.fs_open(filepath, "r", 438)
		if not fd then return end
		local stat = vim.uv.fs_fstat(fd)
		if not stat then vim.uv.fs_close(fd); return end
		if stat.mtime.sec == snap.mtime then vim.uv.fs_close(fd); return end

		local data = vim.uv.fs_read(fd, stat.size, 0)
		vim.uv.fs_close(fd)
		if not data then return end

		-- Compare against stored raw (no table.concat needed)
		if data ~= snap.raw then
			M.mark_changed(filepath)

			local bufnr = vim.fn.bufnr(filepath)
			if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
				vim.api.nvim_buf_call(bufnr, function()
					vim.cmd("checktime")
				end)
			end
		end
	end))

	file_watchers[filepath] = handle
end

function M.setup()
	vim.o.autoread = true

	vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
		group = augroup,
		callback = function(args)
			if vim.bo[args.buf].buftype ~= "" then return end
			local filepath = vim.api.nvim_buf_get_name(args.buf)
			if filepath == "" then return end
			if not snapshots.has(filepath) then
				snapshots.take(filepath)
			end
			watch_file(filepath)
		end,
	})

	-- Only checktime for buffers without an active fs_event watcher
	vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
		group = augroup,
		callback = function()
			if vim.fn.getcmdwintype() ~= "" then return end
			local filepath = vim.api.nvim_buf_get_name(0)
			if filepath ~= "" and not file_watchers[filepath] then
				vim.cmd("checktime")
			end
		end,
	})

	vim.api.nvim_create_autocmd("FileChangedShellPost", {
		group = augroup,
		callback = function(args)
			local filepath = vim.api.nvim_buf_get_name(args.buf)
			if filepath ~= "" and snapshots.has(filepath) then
				M.mark_changed(filepath)
			end
		end,
	})

	-- Clean up on buffer delete, unload, wipeout, or rename
	vim.api.nvim_create_autocmd({ "BufDelete", "BufUnload", "BufWipeout" }, {
		group = augroup,
		callback = function(args)
			local filepath = vim.api.nvim_buf_get_name(args.buf)
			if filepath ~= "" then unwatch_file(filepath) end
		end,
	})

	-- Handle buffer rename (:saveas)
	vim.api.nvim_create_autocmd("BufFilePost", {
		group = augroup,
		callback = function(args)
			local new_path = vim.api.nvim_buf_get_name(args.buf)
			-- Old path watcher is now stale — clean up all non-matching watchers
			-- (we don't have the old name, so just watch the new one)
			if new_path ~= "" then
				if not snapshots.has(new_path) then
					snapshots.take(new_path)
				end
				watch_file(new_path)
			end
		end,
	})
end

function M._reset()
	changed_files = {}
	on_change_callbacks = {}
	-- Don't reset file_watchers — those are libuv handles
end

return M
