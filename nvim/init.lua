vim.deprecate = function() end

require("user.options")
require("user.keymaps")
require("user.lazy")

vim.cmd("colorscheme github_dark_high_contrast")

local builtin = require("telescope.builtin")
vim.keymap.set("n", "<leader>ff", builtin.find_files, { desc = "Telescope find files" })
vim.keymap.set("n", "<leader>fg", builtin.live_grep, { desc = "Telescope live grep" })
vim.keymap.set("n", "<leader>fb", builtin.buffers, { desc = "Telescope buffers" })
vim.keymap.set("n", "<leader>fh", builtin.help_tags, { desc = "Telescope help tags" })

vim.api.nvim_create_autocmd("CursorHold", {
	pattern = "*",
	callback = function()
		vim.diagnostic.open_float(nil, { scope = "cursor" })
	end,
})

vim.api.nvim_create_autocmd("BufReadPost", {
	callback = function()
		if vim.fn.line([['"]]) > 0 and vim.fn.line([['"]]) <= vim.fn.line("$") then
			vim.cmd('normal! g`"')
		end
	end,
})

vim.diagnostic.config({
	float = { focus = false },
})

local llama_group = vim.api.nvim_create_augroup("LlamaToggle", { clear = true })

local function is_nolama()
	return vim.bo.filetype:find("nolama") ~= nil
end

vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
	group = llama_group,
	callback = function()
		if is_nolama() then
			-- Attempt to use built-in command, fallback to manual clearing
			if vim.fn.exists(":LlamaDisable") == 2 then
				vim.cmd("LlamaDisable")
			else
				-- Fallback: Directly clear the plugin's autocommand group
				pcall(vim.api.nvim_clear_autocmds, { group = "llama" })
			end
		end
	end,
})

vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
	group = llama_group,
	callback = function()
		if is_nolama() then
			if vim.fn.exists(":LlamaEnable") == 2 then
				vim.cmd("LlamaEnable")
			else
				-- Fallback: Re-initialize the plugin to restore autocommands
				pcall(vim.fn["llama#init"])
			end
		end
	end,
})
