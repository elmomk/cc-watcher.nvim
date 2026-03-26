-- Telescope extension entry point for cc-watcher.nvim
-- Usage: :Telescope cc_watcher [changed_files|hunks]

return require("telescope").register_extension({
	exports = {
		cc_watcher = function(opts)
			require("cc-watcher.telescope").changed_files(opts)
		end,
		changed_files = function(opts)
			require("cc-watcher.telescope").changed_files(opts)
		end,
		hunks = function(opts)
			require("cc-watcher.telescope").hunks(opts)
		end,
	},
})
