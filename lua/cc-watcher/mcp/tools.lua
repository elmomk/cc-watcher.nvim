-- tools.lua — MCP tool handlers for Claude Code IDE integration
-- Each tool returns (result, err) where result is the MCP content format.

local M = {}

local selection = require("cc-watcher.mcp.selection")
local lockfile = require("cc-watcher.mcp.lockfile")

--- Wrap a text result in MCP content format
---@param data any JSON-serializable value
---@return table MCP content response
local function text_result(data)
	return {
		content = { { type = "text", text = vim.json.encode(data) } },
	}
end

--- Wrap an error
---@param code number JSON-RPC error code
---@param message string
---@return nil, table
local function tool_error(code, message)
	return nil, { code = code, message = message }
end

-- Tool: getWorkspaceFolders
local function get_workspace_folders(_params)
	local paths = lockfile.get_workspace_folders()
	local folders = {}
	for _, path in ipairs(paths) do
		folders[#folders + 1] = {
			name = vim.fn.fnamemodify(path, ":t"),
			uri = "file://" .. path,
			path = path,
		}
	end
	return text_result(folders)
end

-- Tool: getOpenEditors
local function get_open_editors(_params)
	local editors = {}
	local current_buf = vim.api.nvim_get_current_buf()

	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buflisted then
			local name = vim.api.nvim_buf_get_name(bufnr)
			if name ~= "" then
				local ft = vim.filetype.match({ buf = bufnr }) or vim.bo[bufnr].filetype or ""
				editors[#editors + 1] = {
					uri = "file://" .. name,
					name = vim.fn.fnamemodify(name, ":t"),
					languageId = ft,
					isActive = bufnr == current_buf,
					isDirty = vim.bo[bufnr].modified,
				}
			end
		end
	end

	return text_result(editors)
end

-- Tool: checkDocumentDirty
local function check_document_dirty(params)
	local uri = params and params.uri
	if not uri then
		return tool_error(-32602, "missing required parameter: uri")
	end

	local path = uri:gsub("^file://", "")
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			local buf_name = vim.api.nvim_buf_get_name(bufnr)
			if buf_name == path then
				return text_result({
					isDirty = vim.bo[bufnr].modified,
					isUntitled = false,
				})
			end
		end
	end

	-- Buffer not found — not open
	return text_result({ isDirty = false, isUntitled = false })
end

-- Tool: saveDocument
local function save_document(params)
	local uri = params and params.uri
	if not uri then
		return tool_error(-32602, "missing required parameter: uri")
	end

	local path = uri:gsub("^file://", "")
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			local buf_name = vim.api.nvim_buf_get_name(bufnr)
			if buf_name == path and vim.bo[bufnr].modified then
				vim.api.nvim_buf_call(bufnr, function()
					vim.cmd("silent write")
				end)
				return text_result({ saved = true })
			end
		end
	end

	return text_result({ saved = false })
end

-- Tool: getCurrentSelection
local function get_current_selection(_params)
	local sel = selection.get_current()
	if not sel then
		return text_result({
			text = "",
			uri = "",
			fileName = "",
			startLine = 0,
			startColumn = 0,
			endLine = 0,
			endColumn = 0,
		})
	end
	return text_result(sel)
end

-- Tool: getLatestSelection
local function get_latest_selection(_params)
	local sel = selection.get_latest()
	if not sel then
		return text_result({
			text = "",
			uri = "",
			fileName = "",
			startLine = 0,
			startColumn = 0,
			endLine = 0,
			endColumn = 0,
		})
	end
	return text_result(sel)
end

-- Tool: getDiagnostics
local function get_diagnostics(params)
	local uri = params and params.uri
	local bufnr = nil

	if uri then
		local path = uri:gsub("^file://", "")
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == path then
				bufnr = b
				break
			end
		end
	end

	local severity_map = {
		[vim.diagnostic.severity.ERROR] = 1,
		[vim.diagnostic.severity.WARN] = 2,
		[vim.diagnostic.severity.INFO] = 3,
		[vim.diagnostic.severity.HINT] = 4,
	}

	local diags = vim.diagnostic.get(bufnr)
	local result = {}

	for _, d in ipairs(diags) do
		local source_buf = d.bufnr
		local source_name = ""
		if source_buf and vim.api.nvim_buf_is_valid(source_buf) then
			source_name = vim.api.nvim_buf_get_name(source_buf)
		end

		result[#result + 1] = {
			uri = source_name ~= "" and ("file://" .. source_name) or (uri or ""),
			range = {
				start = { line = d.lnum, character = d.col },
				["end"] = { line = d.end_lnum or d.lnum, character = d.end_col or d.col },
			},
			severity = severity_map[d.severity] or 1,
			message = d.message,
			source = d.source or "",
			code = d.code,
		}
	end

	return text_result(result)
end

-- Tool: openFile
local function open_file(params)
	local uri = params and params.uri
	if not uri then
		return tool_error(-32602, "missing required parameter: uri")
	end

	local path = uri:gsub("^file://", "")
	vim.cmd("edit " .. vim.fn.fnameescape(path))

	-- Search for startText/endText if provided
	local start_text = params.startText
	local end_text = params.endText
	if start_text then
		local found = vim.fn.search(vim.fn.escape(start_text, "/\\"), "w")
		if found > 0 then
			vim.cmd("normal! zz")
		end
	elseif end_text then
		local found = vim.fn.search(vim.fn.escape(end_text, "/\\"), "w")
		if found > 0 then
			vim.cmd("normal! zz")
		end
	end

	return text_result({ opened = true })
end

-- Tool: closeAllDiffTabs — implemented via server's pending_diffs
-- This is a stub; actual close logic is wired by the server module.
local close_all_diffs_fn = nil

function M.set_close_all_diffs(fn)
	close_all_diffs_fn = fn
end

local function close_all_diff_tabs(_params)
	if close_all_diffs_fn then
		close_all_diffs_fn()
	end
	return text_result({ closed = true })
end

-- Tool: openDiff — deferred response, resolved on user accept/reject
-- This is a stub; actual logic is wired by the server module via set_open_diff.
local open_diff_fn = nil

function M.set_open_diff(fn)
	open_diff_fn = fn
end

local function open_diff(params, context)
	if not open_diff_fn then
		return tool_error(-32603, "openDiff not initialized")
	end
	return open_diff_fn(params, context)
end

--- Tool registry — O(1) lookup by name
M.registry = {
	getWorkspaceFolders = {
		handler = get_workspace_folders,
		description = "Get workspace folders",
	},
	getOpenEditors = {
		handler = get_open_editors,
		description = "Get open editor tabs",
	},
	checkDocumentDirty = {
		handler = check_document_dirty,
		description = "Check if a document has unsaved changes",
	},
	saveDocument = {
		handler = save_document,
		description = "Save a document",
	},
	getCurrentSelection = {
		handler = get_current_selection,
		description = "Get current text selection",
	},
	getLatestSelection = {
		handler = get_latest_selection,
		description = "Get latest non-empty selection",
	},
	getDiagnostics = {
		handler = get_diagnostics,
		description = "Get diagnostics (errors, warnings)",
	},
	openFile = {
		handler = open_file,
		description = "Open a file in the editor",
	},
	closeAllDiffTabs = {
		handler = close_all_diff_tabs,
		description = "Close all open diff tabs",
	},
	openDiff = {
		handler = open_diff,
		description = "Open a diff view for file changes",
		deferred = true,
	},
}

--- Execute a tool by name
---@param name string tool name
---@param params table tool parameters
---@param context table|nil extra context (connection_id, request_id)
---@return table|nil result, table|nil error
function M.execute(name, params, context)
	local tool = M.registry[name]
	if not tool then
		return nil, { code = -32601, message = "unknown tool: " .. tostring(name) }
	end

	local ok, result, err = pcall(tool.handler, params, context)
	if not ok then
		return nil, { code = -32603, message = "tool error: " .. tostring(result) }
	end

	return result, err
end

--- Check if a tool uses deferred responses
---@param name string
---@return boolean
function M.is_deferred(name)
	local tool = M.registry[name]
	return tool ~= nil and tool.deferred == true
end

--- Get list of tool definitions for MCP tools/list
---@return table[]
function M.list()
	local result = {}
	for name, tool in pairs(M.registry) do
		result[#result + 1] = {
			name = name,
			description = tool.description,
			inputSchema = {
				type = "object",
				properties = {},
			},
		}
	end
	return result
end

return M
