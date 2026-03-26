-- Proxy: trouble.nvim auto-discovers sources from lua/trouble/sources/*.lua
-- This delegates to the actual implementation in cc-watcher.
return require("cc-watcher.trouble")
