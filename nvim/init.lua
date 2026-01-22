vim.deprecate = function() end

require("user.options")
require("user.keymaps")
require("user.lazy")

vim.cmd('colorscheme github_dark_high_contrast')

local builtin = require('telescope.builtin')
vim.keymap.set('n', '<leader>ff', builtin.find_files,   { desc = 'Telescope find files' })
vim.keymap.set('n', '<leader>fg', builtin.live_grep,    { desc = 'Telescope live grep' })
vim.keymap.set('n', '<leader>fb', builtin.buffers,      { desc = 'Telescope buffers' })
vim.keymap.set('n', '<leader>fh', builtin.help_tags,    { desc = 'Telescope help tags' })

vim.api.nvim_create_autocmd('CursorHold', {
  pattern = '*',
  callback = function()
    vim.diagnostic.open_float(nil, { scope = 'cursor' })
  end,
})

vim.api.nvim_create_autocmd("BufReadPost", {
  callback = function()
    if vim.fn.line([['"]])>0 and vim.fn.line([['"]])<=vim.fn.line("$") then
      vim.cmd('normal! g`"')
    end
  end,
})
