-- highlights.lua — All highlight groups, linked to semantic defaults.
-- Adapts to any colorscheme (dark or light). Users can override any group.

local M = {}

local defined = false

function M.setup()
	if defined then return end
	defined = true

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
	hl("ClaudeDir",      { link = "Directory" })
	hl("ClaudeFile",        { link = "Normal" })
	hl("ClaudeFileCurrent", { bold = true, underline = true, link = "Normal" })
	hl("ClaudeFileLatest",  { italic = true, link = "DiagnosticWarn" })
	hl("ClaudeHelp",     { link = "Comment" })
	hl("ClaudeStats",    { link = "Comment" })

	-- Diff inline: link to built-in diff groups
	hl("ClaudeDiffAdd",        { link = "DiffAdd" })
	hl("ClaudeDiffChange",     { link = "DiffChange" })
	hl("ClaudeDiffDelete",     { link = "DiffDelete" })
	hl("ClaudeDiffDeleteNr",   { link = "DiagnosticError" })
	hl("ClaudeDiffAddSign",    { link = "Added" })
	hl("ClaudeDiffChangeSign", { link = "Changed" })
	hl("ClaudeDiffDeleteSign", { link = "Removed" })
end

return M
