-- General
vim.g.mapleader = " "
vim.g.maplocalleader = " "
vim.g.have_nerd_font = false

-- Options
vim.o.encoding = "utf-8"
vim.o.hidden = true
vim.o.ttyfast = true
vim.o.updatetime = 250
vim.o.timeoutlen = 0
vim.o.signcolumn = "yes"
vim.o.undofile = true
vim.o.splitright = true
vim.o.splitbelow = true
vim.o.list = true
vim.o.inccommand = "split"
vim.o.scrolloff = 10
vim.o.confirm = true
vim.o.showmode = false
vim.o.breakindent = true
vim.o.ignorecase = true
vim.o.smartcase = true

-- Numbers
vim.o.number = true
vim.o.relativenumber = true

-- Tabs and Indentation
vim.o.expandtab = true
vim.o.tabstop = 4
vim.o.softtabstop = 4
vim.o.shiftwidth = 4
vim.o.cindent = true

-- Search
vim.o.hlsearch = true
vim.o.incsearch = true

-- Appearance
vim.o.termguicolors = true
vim.o.cursorline = true

-- Mouse
vim.o.mouse = "a"

-- Sync with OS clipboard
vim.schedule(function()
	vim.o.clipboard = "unnamedplus"
end)

-- Comments
vim.cmd("iabbrev ee ///////////////////////////////////////////////////////////////////////////")
