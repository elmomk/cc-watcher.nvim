-- server.lua — WebSocket server for MCP JSON-RPC communication
-- TCP listener on 127.0.0.1, RFC 6455 handshake, frame parser/writer,
-- JSON-RPC 2.0 dispatch. Fixes known issues from coder/claudecode.nvim.

local M = {}

local uv = vim.uv
local bit = require("bit")
local crypto = require("cc-watcher.mcp.crypto")
local tools = require("cc-watcher.mcp.tools")

-- Constants
local OPCODES = {
	CONTINUATION = 0x0,
	TEXT = 0x1,
	BINARY = 0x2,
	CLOSE = 0x8,
	PING = 0x9,
	PONG = 0xA,
}

-- State
local tcp_server = nil
local auth_token = nil
local clients = {}         -- connection_id -> client object
local next_conn_id = 1
local pending_diffs = {}   -- "{conn_id}:{req_id}" -> { timer, bufnr, resolve }
local config = {
	port_range = { 10000, 65535 },
	max_connections = 2,
	max_send_queue = 1000,
	ping_interval_ms = 30000,
	diff_timeout_ms = 300000,
	diff_layout = "inline",
}

-- Forward declarations
local close_client
local encode_frame
local send_frame
local send_ping

--- Set server configuration
---@param cfg table
function M.configure(cfg)
	if cfg.port_range then config.port_range = cfg.port_range end
	if cfg.max_connections then config.max_connections = cfg.max_connections end
	if cfg.max_send_queue then config.max_send_queue = cfg.max_send_queue end
	if cfg.ping_interval_ms then config.ping_interval_ms = cfg.ping_interval_ms end
	if cfg.diff_timeout_ms then config.diff_timeout_ms = cfg.diff_timeout_ms end
	if cfg.diff_layout then config.diff_layout = cfg.diff_layout end
end

--- Set auth token for handshake validation
---@param token string
function M.set_auth_token(token)
	auth_token = token
end

----------------------------------------------------------------------
-- Frame encoding
----------------------------------------------------------------------

--- Encode a WebSocket frame (server → client, unmasked)
---@param payload string
---@param opcode number
---@return string
encode_frame = function(payload, opcode)
	local len = #payload
	local header

	if len <= 125 then
		header = string.char(0x80 + opcode, len)
	elseif len <= 0xFFFF then
		header = string.char(
			0x80 + opcode, 126,
			bit.rshift(len, 8), bit.band(len, 0xFF)
		)
	else
		-- 8-byte length (Lua ints are fine for < 2^53)
		header = string.char(
			0x80 + opcode, 127,
			0, 0, 0, 0,
			bit.band(bit.rshift(len, 24), 0xFF),
			bit.band(bit.rshift(len, 16), 0xFF),
			bit.band(bit.rshift(len, 8), 0xFF),
			bit.band(len, 0xFF)
		)
	end

	return header .. payload
end

--- Encode and send a text frame to a client
---@param client table client object
---@param data string payload
send_frame = function(client, data)
	if not client.socket or client.closing then return end

	-- Backpressure: drop if queue too large
	client.send_queue_size = (client.send_queue_size or 0) + 1
	if client.send_queue_size > config.max_send_queue then
		client.send_queue_size = client.send_queue_size - 1
		return
	end

	local frame = encode_frame(data, OPCODES.TEXT)
	client.socket:write(frame, function(err)
		client.send_queue_size = (client.send_queue_size or 1) - 1
		if err then
			close_client(client, "write error: " .. tostring(err))
		end
	end)
end

--- Send a ping frame
---@param client table
send_ping = function(client)
	if not client.socket or client.closing then return end
	local frame = encode_frame("", OPCODES.PING)
	client.socket:write(frame)
end

----------------------------------------------------------------------
-- JSON-RPC helpers
----------------------------------------------------------------------

--- Send a JSON-RPC response
---@param client table
---@param id any request id
---@param result table|nil
---@param error table|nil
local function send_response(client, id, result, err)
	local msg = { jsonrpc = "2.0", id = id }
	if err then
		msg.error = err
	else
		msg.result = result
	end
	send_frame(client, vim.json.encode(msg))
end

--- Broadcast a JSON-RPC notification to all clients
---@param method string
---@param params table|nil
function M.broadcast(method, params)
	local msg = vim.json.encode({
		jsonrpc = "2.0",
		method = method,
		params = params,
	})
	for _, client in pairs(clients) do
		if client.handshake_done and not client.closing then
			send_frame(client, msg)
		end
	end
end

----------------------------------------------------------------------
-- Frame decoding (incremental state machine)
----------------------------------------------------------------------

--- Parse frames from accumulated buffer data
---@param client table client object with .buf (table of chunks), .buf_len
---@return table[] frames array of { opcode, payload, fin }
local function parse_frames(client)
	local frames = {}
	-- Flatten buffer
	local data = table.concat(client.buf)
	client.buf = { data }
	client.buf_len = #data

	local pos = 1
	while pos <= #data do
		-- Need at least 2 bytes for header
		if pos + 1 > #data then break end

		local b1 = data:byte(pos)
		local b2 = data:byte(pos + 1)
		local fin = bit.band(b1, 0x80) ~= 0
		local opcode = bit.band(b1, 0x0F)
		local masked = bit.band(b2, 0x80) ~= 0
		local payload_len = bit.band(b2, 0x7F)
		local header_len = 2

		if payload_len == 126 then
			if pos + 3 > #data then break end
			payload_len = bit.lshift(data:byte(pos + 2), 8) + data:byte(pos + 3)
			header_len = 4
		elseif payload_len == 127 then
			if pos + 9 > #data then break end
			-- Read lower 32 bits only (sufficient for our payloads)
			payload_len = bit.lshift(data:byte(pos + 6), 24)
				+ bit.lshift(data:byte(pos + 7), 16)
				+ bit.lshift(data:byte(pos + 8), 8)
				+ data:byte(pos + 9)
			header_len = 10
		end

		local mask_key
		if masked then
			if pos + header_len + 3 > #data then break end
			mask_key = data:sub(pos + header_len, pos + header_len + 3)
			header_len = header_len + 4
		end

		local total = header_len + payload_len
		if pos + total - 1 > #data then break end

		local payload = data:sub(pos + header_len, pos + total - 1)

		-- Unmask if needed (client → server frames are always masked per RFC 6455)
		if masked and mask_key then
			local unmasked = {}
			for i = 1, #payload do
				local j = ((i - 1) % 4) + 1
				unmasked[#unmasked + 1] = string.char(bit.bxor(payload:byte(i), mask_key:byte(j)))
			end
			payload = table.concat(unmasked)
		end

		frames[#frames + 1] = { opcode = opcode, payload = payload, fin = fin }
		pos = pos + total
	end

	-- Keep remaining unparsed data
	if pos > 1 then
		local remaining = data:sub(pos)
		client.buf = { remaining }
		client.buf_len = #remaining
	end

	return frames
end

----------------------------------------------------------------------
-- HTTP handshake
----------------------------------------------------------------------

--- Parse HTTP upgrade request
---@param data string raw HTTP request
---@return table|nil headers, string|nil error
local function parse_handshake(data)
	local lines = {}
	for line in data:gmatch("([^\r\n]*)\r?\n") do
		lines[#lines + 1] = line
	end

	if #lines < 1 then return nil, "empty request" end

	-- First line: GET / HTTP/1.1
	local method, path = lines[1]:match("^(%S+)%s+(%S+)")
	if method ~= "GET" then return nil, "not GET" end

	local headers = { path = path }
	for i = 2, #lines do
		local key, value = lines[i]:match("^([^:]+):%s*(.*)")
		if key then
			headers[key:lower()] = value
		end
	end

	return headers
end

--- Perform WebSocket handshake
---@param client table
---@param data string
---@return boolean success
local function do_handshake(client, data)
	local headers, err = parse_handshake(data)
	if not headers then
		local response = "HTTP/1.1 400 Bad Request\r\n\r\n" .. (err or "bad request")
		client.socket:write(response, function()
			close_client(client, "bad handshake")
		end)
		return false
	end

	-- Validate upgrade
	local upgrade = (headers["upgrade"] or ""):lower()
	if upgrade ~= "websocket" then
		client.socket:write("HTTP/1.1 400 Bad Request\r\n\r\nNot a WebSocket request", function()
			close_client(client, "not websocket")
		end)
		return false
	end

	-- Validate auth token
	local client_token = headers["x-claude-code-ide-authorization"]
	if auth_token and client_token ~= auth_token then
		client.socket:write("HTTP/1.1 401 Unauthorized\r\n\r\n", function()
			close_client(client, "auth failed")
		end)
		return false
	end

	-- Compute accept key
	local ws_key = headers["sec-websocket-key"]
	if not ws_key then
		client.socket:write("HTTP/1.1 400 Bad Request\r\n\r\nMissing Sec-WebSocket-Key", function()
			close_client(client, "no ws key")
		end)
		return false
	end

	local accept = crypto.ws_accept_key(ws_key)
	-- Echo back Sec-WebSocket-Protocol if client requested one (Claude uses "mcp")
	local protocol_header = ""
	local requested_protocol = headers["sec-websocket-protocol"]
	if requested_protocol then
		-- Take the first protocol from the comma-separated list
		local first = requested_protocol:match("^%s*([^,]+)")
		if first then
			protocol_header = "Sec-WebSocket-Protocol: " .. first:match("^%s*(.-)%s*$") .. "\r\n"
		end
	end
	local response = "HTTP/1.1 101 Switching Protocols\r\n"
		.. "Upgrade: websocket\r\n"
		.. "Connection: Upgrade\r\n"
		.. "Sec-WebSocket-Accept: " .. accept .. "\r\n"
		.. protocol_header
		.. "\r\n"

	client.socket:write(response, function(write_err)
		if write_err then
			close_client(client, "handshake write error")
			return
		end
		-- State transition AFTER write confirms (fix for coder/claudecode race)
		client.handshake_done = true

		-- Start ping timer
		if config.ping_interval_ms > 0 then
			client.ping_timer = uv.new_timer()
			client.ping_timer:start(config.ping_interval_ms, config.ping_interval_ms, function()
				vim.schedule(function()
					if client.handshake_done and not client.closing then
						send_ping(client)
					end
				end)
			end)
		end
	end)

	return true
end

----------------------------------------------------------------------
-- JSON-RPC dispatch
----------------------------------------------------------------------

--- Handle a complete JSON-RPC message
---@param client table
---@param payload string JSON text
local function handle_message(client, payload)
	local ok, msg = pcall(vim.json.decode, payload)
	if not ok or type(msg) ~= "table" then
		send_response(client, vim.NIL, nil, { code = -32700, message = "parse error" })
		return
	end

	-- Notification (no id) — handle known notifications, ignore rest
	if msg.id == nil then
		-- notifications/initialized: client confirms init — no response needed
		return
	end

	local method = msg.method
	if not method then
		send_response(client, msg.id, nil, { code = -32600, message = "invalid request" })
		return
	end

	-- JSON-RPC method → MCP tool mapping
	-- MCP uses "tools/call" with params.name, or direct method names
	local tool_name = method
	local tool_params = msg.params or {}

	if method == "tools/call" then
		tool_name = tool_params.name
		tool_params = tool_params.arguments or {}
	elseif method == "tools/list" then
		send_response(client, msg.id, { tools = tools.list() })
		return
	elseif method == "initialize" then
		send_response(client, msg.id, {
			protocolVersion = "2024-11-05",
			capabilities = {
				tools = { listChanged = false },
			},
			serverInfo = {
				name = "cc-watcher-mcp",
				version = "1.0.0",
			},
		})
		return
	end

	-- Check if this is a deferred tool (like openDiff)
	if tools.is_deferred(tool_name) then
		local context = {
			connection_id = client.id,
			request_id = msg.id,
			send_response = function(result, err)
				vim.schedule(function()
					send_response(client, msg.id, result, err)
				end)
			end,
		}

		vim.schedule(function()
			local result, err = tools.execute(tool_name, tool_params, context)
			-- Deferred tools don't respond immediately (response sent via context.send_response)
			if err then
				send_response(client, msg.id, nil, err)
			end
			-- If result is returned synchronously (error case), send it
			if result and not tools.is_deferred(tool_name) then
				send_response(client, msg.id, result)
			end
		end)
		return
	end

	-- Regular (synchronous) tool — schedule on main thread
	vim.schedule(function()
		local result, err = tools.execute(tool_name, tool_params)
		if err then
			send_response(client, msg.id, nil, err)
		else
			send_response(client, msg.id, result)
		end
	end)
end

----------------------------------------------------------------------
-- Client connection management
----------------------------------------------------------------------

--- Close a client connection
---@param client table
---@param reason string|nil
close_client = function(client, reason)
	if client.closing then return end
	client.closing = true

	-- Clean up pending diffs for this connection
	for key, diff_info in pairs(pending_diffs) do
		if key:match("^" .. client.id .. ":") then
			if diff_info.timer then
				diff_info.timer:stop()
				if not diff_info.timer:is_closing() then
					diff_info.timer:close()
				end
			end
			pending_diffs[key] = nil
		end
	end

	-- Stop ping timer
	if client.ping_timer then
		client.ping_timer:stop()
		if not client.ping_timer:is_closing() then
			client.ping_timer:close()
		end
		client.ping_timer = nil
	end

	-- Close socket
	if client.socket and not client.socket:is_closing() then
		client.socket:read_stop()
		client.socket:close()
	end

	-- Remove from clients table
	clients[client.id] = nil

	if reason then
		vim.schedule(function()
			vim.notify("[cc-watcher/mcp] client " .. client.id .. " disconnected: " .. reason, vim.log.levels.DEBUG)
		end)
	end
end

--- Handle new TCP connection
---@param err string|nil
local function on_connection(err)
	if err then return end
	if not tcp_server then return end

	local socket = uv.new_tcp()
	tcp_server:accept(socket)

	-- Connection limit check
	local count = 0
	for _ in pairs(clients) do count = count + 1 end
	if count >= config.max_connections then
		socket:write("HTTP/1.1 503 Service Unavailable\r\n\r\nMax connections reached", function()
			if not socket:is_closing() then
				socket:close()
			end
		end)
		return
	end

	local conn_id = next_conn_id
	next_conn_id = next_conn_id + 1

	local client = {
		id = conn_id,
		socket = socket,
		handshake_done = false,
		closing = false,
		buf = {},
		buf_len = 0,
		send_queue_size = 0,
		fragment_opcode = nil,
		fragment_parts = {},
	}
	clients[conn_id] = client

	socket:read_start(function(read_err, data)
		if read_err then
			vim.schedule(function() close_client(client, "read error") end)
			return
		end

		if not data then
			vim.schedule(function() close_client(client, "connection closed") end)
			return
		end

		-- Accumulate data (table.insert, not string concat — O(1) amortized)
		client.buf[#client.buf + 1] = data
		client.buf_len = client.buf_len + #data

		if not client.handshake_done then
			-- Check if we have a complete HTTP request (ends with \r\n\r\n)
			local full = table.concat(client.buf)
			if full:find("\r\n\r\n") then
				client.buf = {}
				client.buf_len = 0
				vim.schedule(function()
					do_handshake(client, full)
				end)
			end
			return
		end

		-- Parse WebSocket frames
		local frames = parse_frames(client)
		for _, frame in ipairs(frames) do
			if frame.opcode == OPCODES.CLOSE then
				vim.schedule(function() close_client(client, "close frame") end)
				return
			elseif frame.opcode == OPCODES.PING then
				-- Reply with pong
				local pong = encode_frame(frame.payload, OPCODES.PONG)
				socket:write(pong)
			elseif frame.opcode == OPCODES.PONG then
				-- Pong received — connection is alive
			elseif frame.opcode == OPCODES.TEXT or frame.opcode == OPCODES.BINARY then
				if frame.fin then
					-- Complete message
					if #client.fragment_parts > 0 then
						-- Final fragment of a fragmented message
						client.fragment_parts[#client.fragment_parts + 1] = frame.payload
						local full_payload = table.concat(client.fragment_parts)
						client.fragment_parts = {}
						client.fragment_opcode = nil
						vim.schedule(function()
							handle_message(client, full_payload)
						end)
					else
						vim.schedule(function()
							handle_message(client, frame.payload)
						end)
					end
				else
					-- Start of fragmented message
					client.fragment_opcode = frame.opcode
					client.fragment_parts = { frame.payload }
				end
			elseif frame.opcode == OPCODES.CONTINUATION then
				if #client.fragment_parts > 0 then
					client.fragment_parts[#client.fragment_parts + 1] = frame.payload
					if frame.fin then
						local full_payload = table.concat(client.fragment_parts)
						client.fragment_parts = {}
						client.fragment_opcode = nil
						vim.schedule(function()
							handle_message(client, full_payload)
						end)
					end
				end
			end
		end
	end)
end

----------------------------------------------------------------------
-- openDiff implementation
----------------------------------------------------------------------

--- Find a suitable editor window (skip terminals, sidebars, floats)
---@return number|nil winid
local function find_editor_window()
	local dominated = {
		"neo-tree", "NvimTree", "oil", "minifiles", "netrw",
		"aerial", "tagbar", "snacks_picker_list", "cc-watcher",
	}
	local dominated_set = {}
	for _, ft in ipairs(dominated) do dominated_set[ft] = true end

	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_is_valid(win) then
			local win_cfg = vim.api.nvim_win_get_config(win)
			if not win_cfg.relative or win_cfg.relative == "" then
				local buf = vim.api.nvim_win_get_buf(win)
				local bt = vim.bo[buf].buftype
				local ft = vim.bo[buf].filetype
				if bt ~= "terminal" and bt ~= "prompt" and not dominated_set[ft] then
					return win
				end
			end
		end
	end
	return nil
end

--- Close a single diff and resolve its deferred response
---@param key string pending diff key
---@param result string "FILE_SAVED" or "DIFF_REJECTED"
local function resolve_diff(key, result)
	local diff_info = pending_diffs[key]
	if not diff_info then return end
	diff_info.resolving = true

	-- Stop timeout timer
	if diff_info.timer then
		diff_info.timer:stop()
		if not diff_info.timer:is_closing() then
			diff_info.timer:close()
		end
	end

	-- Clean up autocmds
	if diff_info.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, diff_info.augroup)
	end

	-- Close proposed buffer windows and delete buffer
	if diff_info.proposed_bufnr and vim.api.nvim_buf_is_valid(diff_info.proposed_bufnr) then
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == diff_info.proposed_bufnr then
				pcall(vim.api.nvim_win_close, win, true)
			end
		end
		pcall(vim.api.nvim_buf_delete, diff_info.proposed_bufnr, { force = true })
	end

	-- Turn off diff mode in original buffer window
	if diff_info.orig_win and vim.api.nvim_win_is_valid(diff_info.orig_win) then
		vim.api.nvim_win_call(diff_info.orig_win, function()
			vim.cmd("diffoff")
		end)
	end

	-- Send response
	if diff_info.send_response then
		diff_info.send_response(
			{ content = { { type = "text", text = vim.json.encode(result) } } },
			nil
		)
	end

	pending_diffs[key] = nil
end

--- Close all pending diffs (for closeAllDiffTabs)
local function close_all_diffs()
	for key, _ in pairs(pending_diffs) do
		resolve_diff(key, "DIFF_REJECTED")
	end
end

--- Open a diff view for a file change (deferred tool)
--- Accept via :w, reject via :q — native Neovim workflow.
---@param params table { old_file_path, new_file_contents, tab_name }
---@param context table { connection_id, request_id, send_response }
---@return nil, table|nil error (deferred — response sent later)
local function handle_open_diff(params, context)
	if not params then
		return nil, { code = -32602, message = "missing params" }
	end

	local file_path = params.old_file_path or params.filePath
	local new_contents = params.new_file_contents or params.newFileContents
	local tab_name = params.tab_name or params.tabName or "Diff"

	if not file_path or not new_contents then
		return nil, { code = -32602, message = "missing old_file_path or new_file_contents" }
	end

	local key = context.connection_id .. ":" .. context.request_id
	local is_new_file = not uv.fs_stat(file_path)

	-- Find a suitable window to show the diff
	local target_win = find_editor_window()
	if target_win then
		vim.api.nvim_set_current_win(target_win)
	end

	-- Open or create the original file buffer (left side)
	local orig_bufnr, orig_win
	if is_new_file then
		-- New file: create an empty readonly buffer
		orig_bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(orig_bufnr, file_path .. " (NEW FILE)")
		vim.bo[orig_bufnr].buftype = "nofile"
		vim.bo[orig_bufnr].modifiable = false
		vim.bo[orig_bufnr].readonly = true
		vim.api.nvim_set_current_buf(orig_bufnr)
	else
		vim.cmd("edit " .. vim.fn.fnameescape(file_path))
		orig_bufnr = vim.api.nvim_get_current_buf()
	end
	orig_win = vim.api.nvim_get_current_win()

	-- Detect filetype for the proposed buffer
	local ft = vim.filetype.match({ filename = file_path }) or vim.bo[orig_bufnr].filetype or ""

	-- Create proposed buffer (right side) — editable, acwrite intercepts :w
	local proposed_bufnr = vim.api.nvim_create_buf(false, true)
	local proposed_name = tab_name .. " (proposed)"
	-- Avoid name collisions
	pcall(vim.api.nvim_buf_set_name, proposed_bufnr, proposed_name)
	local lines = vim.split(new_contents, "\n", { plain = true })
	vim.api.nvim_buf_set_lines(proposed_bufnr, 0, -1, false, lines)
	vim.bo[proposed_bufnr].filetype = ft
	vim.bo[proposed_bufnr].buftype = "acwrite"  -- :w triggers BufWriteCmd, no disk write
	vim.bo[proposed_bufnr].swapfile = false
	vim.bo[proposed_bufnr].modifiable = true     -- user can edit before accepting

	-- Store the diff key on the buffer for command-based accept/reject
	vim.b[proposed_bufnr].cc_mcp_diff_key = key

	local proposed_win
	if config.diff_layout == "inline" then
		-- Inline layout: replace the original buffer in the same window
		vim.api.nvim_set_current_buf(proposed_bufnr)
		proposed_win = vim.api.nvim_get_current_win()
	else
		-- Vertical split layout (default): original left, proposed right
		vim.cmd("diffthis")
		vim.cmd("vertical rightbelow sbuffer " .. proposed_bufnr)
		vim.cmd("diffthis")
		vim.cmd("wincmd =")
		proposed_win = vim.api.nvim_get_current_win()
	end

	-- Virtual text hint — :w to accept, :q to reject
	local ns = vim.api.nvim_create_namespace("cc_watcher_mcp_diff")
	pcall(vim.api.nvim_buf_set_extmark, proposed_bufnr, ns, 0, 0, {
		virt_text = {
			{ "  Accept: ", "ClaudeMcpDiffHeader" },
			{ ":w", "ClaudeMcpDiffAccept" },
			{ "  Reject: ", "ClaudeMcpDiffHeader" },
			{ ":q", "ClaudeMcpDiffReject" },
			{ "  ", "Normal" },
		},
		virt_text_pos = "right_align",
	})

	-- Store pending diff info
	local diff_info = {
		send_response = context.send_response,
		proposed_bufnr = proposed_bufnr,
		orig_bufnr = orig_bufnr,
		orig_win = orig_win,
		file_path = file_path,
		is_new_file = is_new_file,
	}

	-- Autocmd group for this diff's lifecycle
	local augroup = vim.api.nvim_create_augroup("CcMcpDiff_" .. key:gsub(":", "_"), { clear = true })
	diff_info.augroup = augroup

	-- Accept: :w triggers BufWriteCmd — read buffer contents and write to file
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = augroup,
		buffer = proposed_bufnr,
		callback = function()
			if diff_info.resolving then return end
			-- Read the (possibly edited) proposed buffer contents
			local final_lines = vim.api.nvim_buf_get_lines(proposed_bufnr, 0, -1, false)
			local final_contents = table.concat(final_lines, "\n") .. "\n"

			-- Write to disk
			local fd = uv.fs_open(file_path, "w", 384) -- 0600
			if fd then
				uv.fs_write(fd, final_contents, 0)
				uv.fs_close(fd)
			end

			-- Reload original buffer from disk
			if vim.api.nvim_buf_is_valid(orig_bufnr) and not is_new_file then
				vim.api.nvim_buf_call(orig_bufnr, function()
					vim.cmd("edit!")
				end)
			end

			-- Mark proposed buffer as unmodified so :q doesn't warn
			vim.bo[proposed_bufnr].modified = false

			resolve_diff(key, "FILE_SAVED")
		end,
	})

	-- Reject: closing/deleting the proposed buffer
	vim.api.nvim_create_autocmd({ "BufDelete", "BufUnload" }, {
		group = augroup,
		buffer = proposed_bufnr,
		callback = function()
			if diff_info.resolving then return end
			-- Defer to avoid issues during buffer teardown
			vim.schedule(function()
				resolve_diff(key, "DIFF_REJECTED")
			end)
		end,
	})

	-- Timeout timer
	local timer = uv.new_timer()
	timer:start(config.diff_timeout_ms, 0, function()
		vim.schedule(function()
			vim.notify("[cc-watcher/mcp] diff timed out for " .. vim.fn.fnamemodify(file_path, ":t"), vim.log.levels.WARN)
			resolve_diff(key, "DIFF_REJECTED")
		end)
	end)
	diff_info.timer = timer
	pending_diffs[key] = diff_info

	-- Focus the proposed window
	vim.api.nvim_set_current_win(proposed_win)

	-- Return nil — response will be sent via resolve_diff
	return nil
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

--- Start the WebSocket server
---@param port_range table { min, max }
---@return number|nil port, string|nil error
function M.start(port_range)
	if tcp_server then
		return nil, "server already running"
	end

	config.port_range = port_range or config.port_range
	local min_port = config.port_range[1]
	local max_port = config.port_range[2]

	-- Wire up openDiff and closeAllDiffTabs
	tools.set_open_diff(handle_open_diff)
	tools.set_close_all_diffs(close_all_diffs)

	-- Bind-first: try random ports, no test-then-bind race
	local server = uv.new_tcp()
	local bound_port = nil
	local max_attempts = 50

	for _ = 1, max_attempts do
		local port = math.random(min_port, max_port)
		local ok, bind_err = pcall(function()
			server:bind("127.0.0.1", port)
		end)
		if ok then
			bound_port = port
			break
		end
		-- EADDRINUSE — try another port
		if bind_err and not tostring(bind_err):find("EADDRINUSE") then
			server:close()
			return nil, "bind error: " .. tostring(bind_err)
		end
		-- Re-create server handle after failed bind
		if not server:is_closing() then
			server:close()
		end
		server = uv.new_tcp()
	end

	if not bound_port then
		if not server:is_closing() then
			server:close()
		end
		return nil, "could not bind to any port in range"
	end

	local listen_err = server:listen(128, on_connection)
	if listen_err and listen_err ~= 0 then
		server:close()
		return nil, "listen error: " .. tostring(listen_err)
	end

	tcp_server = server
	return bound_port
end

--- Stop the server and disconnect all clients
function M.stop()
	-- Close all clients
	for _, client in pairs(clients) do
		close_client(client, "server shutdown")
	end
	clients = {}

	-- Close all pending diffs
	close_all_diffs()

	-- Stop TCP server
	if tcp_server then
		if not tcp_server:is_closing() then
			tcp_server:close()
		end
		tcp_server = nil
	end

	next_conn_id = 1
end

--- Check if server is running
---@return boolean
function M.is_running()
	return tcp_server ~= nil
end

--- Get server status
---@return table { running, port, connections }
function M.status()
	local count = 0
	local handshaked = 0
	for _, client in pairs(clients) do
		count = count + 1
		if client.handshake_done then
			handshaked = handshaked + 1
		end
	end
	return {
		running = tcp_server ~= nil,
		connections = count,
		active_connections = handshaked,
		pending_diffs = vim.tbl_count(pending_diffs),
	}
end

--- Get connected client count
---@return number
function M.client_count()
	local count = 0
	for _, client in pairs(clients) do
		if client.handshake_done and not client.closing then
			count = count + 1
		end
	end
	return count
end

return M
