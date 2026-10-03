vim.deprecate = function() end

require("user.options")
require("user.keymaps")
require("user.lazy")
require("user.autocmd")
require("user.llama")
require("user.asm").setup()
require("user.layout").setup()
require("user.storage").setup()

vim.cmd("colorscheme matrix")

local builtin = require("telescope.builtin")
vim.keymap.set("n", "<leader>ff", builtin.find_files, { desc = "Telescope find files" })
vim.keymap.set("n", "<leader>fg", builtin.live_grep, { desc = "Telescope live grep" })
vim.keymap.set("n", "<leader>fb", builtin.buffers, { desc = "Telescope buffers" })
vim.keymap.set("n", "<leader>fh", builtin.help_tags, { desc = "Telescope help tags" })

vim.diagnostic.config({
	float = { focus = false },
})
