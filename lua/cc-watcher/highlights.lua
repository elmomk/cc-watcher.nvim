-- highlights.lua — All highlight groups, defined once with default = true
-- Users can override any group in their colorscheme.

local M = {}

local defined = false

function M.setup()
	if defined then return end
	defined = true

	local hl = function(name, opts)
		opts.default = true
		vim.api.nvim_set_hl(0, name, opts)
	end

	-- Sidebar
	hl("ClaudeHeader",   { fg = "#cba6f7", bold = true })
	hl("ClaudeActive",   { fg = "#a6e3a1" })
	hl("ClaudeInactive", { fg = "#6c7086", italic = true })
	hl("ClaudeCount",    { fg = "#89b4fa" })
	hl("ClaudeSep",      { fg = "#313244" })
	hl("ClaudeLive",     { fg = "#f9e2af" })
	hl("ClaudeSession",  { fg = "#89b4fa" })
	hl("ClaudeDir",      { fg = "#6c7086" })
	hl("ClaudeFile",     { fg = "#cdd6f4" })
	hl("ClaudeHelp",     { fg = "#585b70" })
	hl("ClaudeStats",    { fg = "#585b70" })

	-- Diff inline (increased bg contrast, no strikethrough — dim text instead)
	hl("ClaudeDiffAdd",        { bg = "#1e4a32", fg = "#a6e3a1" })
	hl("ClaudeDiffChange",     { bg = "#3a3520", fg = "#f9e2af" })
	hl("ClaudeDiffDelete",     { bg = "#3a1a1a", fg = "#7a5060" })  -- dim muted rose
	hl("ClaudeDiffDeleteNr",   { fg = "#f38ba8" })
	hl("ClaudeDiffAddSign",    { fg = "#a6e3a1" })
	hl("ClaudeDiffChangeSign", { fg = "#f9e2af" })
	hl("ClaudeDiffDeleteSign", { fg = "#f38ba8" })
end

return M
