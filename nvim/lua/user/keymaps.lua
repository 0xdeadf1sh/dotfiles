local map = vim.keymap.set

-- Switch buffers
map("n", "<Tab>", ":bnext<CR>", { silent = true })
map("n", "<S-Tab>", ":bprevious<CR>", { silent = true })

-- Close current buffer
map("n", "<leader>q", ":Bclose<CR>", { silent = true })
