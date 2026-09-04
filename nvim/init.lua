vim.deprecate = function() end

require("user.options")
require("user.keymaps")
require("user.lazy")
require("user.autocmd")
require("user.llama")
require("user.asm").setup()
require("user.layout").setup()
require("user.storage").setup()

vim.cmd("colorscheme github_dark_high_contrast")

local builtin = require("telescope.builtin")
vim.keymap.set("n", "<leader>ff", builtin.find_files, { desc = "Telescope find files" })
vim.keymap.set("n", "<leader>fg", builtin.live_grep, { desc = "Telescope live grep" })
vim.keymap.set("n", "<leader>fb", builtin.buffers, { desc = "Telescope buffers" })
vim.keymap.set("n", "<leader>fh", builtin.help_tags, { desc = "Telescope help tags" })

vim.diagnostic.config({
	float = { focus = false },
})

vim.cmd([[
  highlight Normal guibg=none
  highlight NormalNC guibg=none
  highlight LineNr guibg=none
  highlight SignColumn guibg=none
  highlight EndOfBuffer guibg=none
]])
