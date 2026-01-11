local opt = vim.opt

-- General
opt.encoding = "utf-8"
opt.hidden = true
opt.ttyfast = true
opt.updatetime = 300
opt.signcolumn = "yes"
opt.clipboard = "unnamedplus"

-- Numbers
opt.number = true
opt.relativenumber = true

-- Tabs and Indentation
opt.expandtab = true
opt.tabstop = 4
opt.softtabstop = 4
opt.shiftwidth = 4
opt.cindent = true

-- Search
opt.hlsearch = true
opt.incsearch = true

-- Appearance
opt.termguicolors = true
opt.cursorline = true

-- Comments
vim.cmd('iabbrev ee ///////////////////////////////////////////////////////////////////////////')
