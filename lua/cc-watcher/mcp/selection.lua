-- selection.lua — Visual selection tracking for MCP getCurrentSelection/getLatestSelection
-- Tracks current and latest non-empty selections with debounced notifications.

local M = {}

local current = nil   -- current selection (may be empty)
local latest = nil    -- last non-empty selection
local notify_fn = nil -- callback(selection) for WebSocket broadcast
local autocmd_group = nil
local debounce_timer = nil
local buf_terminal_cache = {} -- bufnr -> bool (is terminal?)
local debounce_ms = 100

--- Check if a buffer is a terminal (cached, invalidated on BufDelete)
---@param bufnr number
---@return boolean
local function is_terminal(bufnr)
	if buf_terminal_cache[bufnr] ~= nil then
		return buf_terminal_cache[bufnr]
	end
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return true
	end
	local bt = vim.bo[bufnr].buftype
	buf_terminal_cache[bufnr] = (bt == "terminal")
	return buf_terminal_cache[bufnr]
end

--- Get selection info from current buffer
---@return table|nil selection info
local function capture_selection()
	local bufnr = vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(bufnr) then return nil end
	if is_terminal(bufnr) then return nil end

	local mode = vim.fn.mode()
	-- Only capture in visual modes
	if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
		return nil
	end

	local fname = vim.api.nvim_buf_get_name(bufnr)
	if fname == "" then return nil end

	-- Get visual selection range
	local start_pos = vim.fn.getpos("v")
	local end_pos = vim.fn.getpos(".")
	local start_line = start_pos[2]
	local start_col = start_pos[3]
	local end_line = end_pos[2]
	local end_col = end_pos[3]

	-- Normalize order
	if start_line > end_line or (start_line == end_line and start_col > end_col) then
		start_line, end_line = end_line, start_line
		start_col, end_col = end_col, start_col
	end

	-- Get selected text
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
	if #lines == 0 then return nil end

	local text
	if mode == "V" then
		-- Line-wise: full lines
		text = table.concat(lines, "\n")
	elseif mode == "v" then
		-- Character-wise: trim first and last line
		if #lines == 1 then
			text = lines[1]:sub(start_col, end_col)
		else
			lines[1] = lines[1]:sub(start_col)
			lines[#lines] = lines[#lines]:sub(1, end_col)
			text = table.concat(lines, "\n")
		end
	else
		-- Block-wise: extract columns from each line
		local block = {}
		for _, line in ipairs(lines) do
			block[#block + 1] = line:sub(start_col, end_col)
		end
		text = table.concat(block, "\n")
	end

	if text == "" then return nil end

	local filetype = vim.filetype.match({ buf = bufnr }) or vim.bo[bufnr].filetype or ""

	return {
		text = text,
		uri = "file://" .. fname,
		fileName = fname,
		startLine = start_line - 1, -- 0-indexed for MCP
		startColumn = start_col - 1,
		endLine = end_line - 1,
		endColumn = end_col,
		language = filetype,
	}
end

--- Debounced notification to WebSocket clients
local function schedule_notify()
	if not notify_fn then return end
	if debounce_timer then
		debounce_timer:stop()
		if not debounce_timer:is_closing() then
			debounce_timer:close()
		end
	end
	debounce_timer = vim.uv.new_timer()
	debounce_timer:start(debounce_ms, 0, function()
		debounce_timer:stop()
		if not debounce_timer:is_closing() then
			debounce_timer:close()
		end
		debounce_timer = nil
		vim.schedule(function()
			if notify_fn and current then
				notify_fn(current)
			end
		end)
	end)
end

--- Update selection state
local function on_selection_change()
	local sel = capture_selection()
	current = sel
	if sel then
		latest = sel
	end
	schedule_notify()
end

--- Set up autocmds for selection tracking
---@param opts table { debounce_ms?: number, on_change?: fun(selection: table) }
function M.setup(opts)
	opts = opts or {}
	debounce_ms = opts.debounce_ms or 100
	notify_fn = opts.on_change

	if autocmd_group then
		vim.api.nvim_del_augroup_by_id(autocmd_group)
	end
	autocmd_group = vim.api.nvim_create_augroup("CcWatcherMcpSelection", { clear = true })

	vim.api.nvim_create_autocmd("ModeChanged", {
		group = autocmd_group,
		pattern = "*:[vV\x16]*",
		callback = on_selection_change,
	})

	vim.api.nvim_create_autocmd("ModeChanged", {
		group = autocmd_group,
		pattern = "[vV\x16]*:*",
		callback = function()
			-- Leaving visual mode: clear current but keep latest
			current = nil
			schedule_notify()
		end,
	})

	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group = autocmd_group,
		callback = function()
			local mode = vim.fn.mode()
			if mode == "v" or mode == "V" or mode == "\22" then
				on_selection_change()
			end
		end,
	})

	-- Invalidate terminal cache on buffer delete
	vim.api.nvim_create_autocmd("BufDelete", {
		group = autocmd_group,
		callback = function(ev)
			buf_terminal_cache[ev.buf] = nil
		end,
	})
end

--- Get current selection (may be nil if not in visual mode)
---@return table|nil
function M.get_current()
	return current
end

--- Get latest non-empty selection
---@return table|nil
function M.get_latest()
	return latest
end

--- Tear down autocmds and timers
function M.shutdown()
	if autocmd_group then
		vim.api.nvim_del_augroup_by_id(autocmd_group)
		autocmd_group = nil
	end
	if debounce_timer then
		debounce_timer:stop()
		if not debounce_timer:is_closing() then
			debounce_timer:close()
		end
		debounce_timer = nil
	end
	notify_fn = nil
	current = nil
	latest = nil
	buf_terminal_cache = {}
end

return M
