-- highlights.lua — All highlight groups, linked to semantic defaults.
-- Adapts to any colorscheme (dark or light). Users can override any group.
-- Re-applies on ColorScheme event so fg resolution stays correct.

local M = {}

local function apply()
	local hl = function(name, opts)
		opts.default = true
		vim.api.nvim_set_hl(0, name, opts)
	end

	-- Sidebar: link to semantic groups that adapt to any colorscheme
	hl("ClaudeHeader",   { link = "Title" })
	hl("ClaudeActive",   { link = "DiagnosticOk" })
	hl("ClaudeInactive", { link = "Comment" })
	hl("ClaudeCount",    { link = "Number" })
	hl("ClaudeSep",      { link = "WinSeparator" })
	hl("ClaudeLive",     { link = "DiagnosticWarn" })
	hl("ClaudeSession",  { link = "DiagnosticInfo" })
	hl("ClaudeFile",     { link = "Normal" })
	hl("ClaudeHelp",     { link = "Comment" })
	hl("ClaudeDir",      { link = "Directory" })
	hl("ClaudeTree",     { link = "Comment" })
	hl("ClaudeStats",    { link = "Comment" })

	-- These need resolved fg because link + bold/italic don't combine
	local normal_fg = vim.api.nvim_get_hl(0, { name = "Normal" }).fg
	local warn_fg = vim.api.nvim_get_hl(0, { name = "DiagnosticWarn" }).fg
	hl("ClaudeFileCurrent", { fg = normal_fg, bold = true, underline = true })
	hl("ClaudeFileLatest",  { fg = warn_fg or normal_fg, bold = true, italic = true })
	hl("ClaudeDirLatest",   { fg = warn_fg or normal_fg, bold = true })

	-- Diff inline: link to built-in diff groups
	hl("ClaudeDiffAdd",        { link = "DiffAdd" })
	hl("ClaudeDiffChange",     { link = "DiffChange" })
	hl("ClaudeDiffDelete",     { link = "DiffDelete" })
	hl("ClaudeDiffDeleteNr",   { link = "DiagnosticError" })
	hl("ClaudeDiffAddSign",    { link = "Added" })
	hl("ClaudeDiffChangeSign", { link = "Changed" })
	hl("ClaudeDiffDeleteSign", { link = "Removed" })

	-- MCP diff accept/reject
	hl("ClaudeMcpDiffAccept",  { link = "DiagnosticOk" })
	hl("ClaudeMcpDiffReject",  { link = "DiagnosticError" })
	hl("ClaudeMcpDiffHeader",  { link = "Title" })
end

local registered = false

function M.setup()
	apply()

	if not registered then
		registered = true
		vim.api.nvim_create_autocmd("ColorScheme", {
			callback = apply,
		})
	end
end

return M
