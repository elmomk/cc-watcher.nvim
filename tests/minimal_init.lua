-- Minimal nvim config for running tests headless
vim.opt.rtp:prepend(".")
vim.opt.rtp:prepend("deps/mini.nvim")

vim.o.swapfile = false
vim.o.shadafile = "NONE"

require("mini.test").setup()
