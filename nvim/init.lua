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

-- 1. Detect the marker when a file is opened
vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
	group = llama_group,
	callback = function()
		-- Scan the first 5 lines for the "llama:disable" string
		local lines = vim.api.nvim_buf_get_lines(0, 0, 5, false)
		for _, line in ipairs(lines) do
			if line:find("llama:disable") then
				vim.b.llama_disabled = true
				break
			end
		end
	end,
})

-- 2. Toggle Llama globally based on the current buffer's setting
vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
	group = llama_group,
	callback = function()
		if vim.b.llama_disabled then
			-- Disable llama for this buffer/window
			if vim.fn.exists(":LlamaDisable") == 2 then
				vim.cmd("LlamaDisable")
			else
				pcall(vim.api.nvim_clear_autocmds, { group = "llama" })
			end
		else
			-- Re-enable llama when entering a normal buffer
			if vim.fn.exists(":LlamaEnable") == 2 then
				vim.cmd("LlamaEnable")
			elseif vim.fn.exists("*llama#init") == 1 then
				pcall(vim.fn["llama#init"])
			end
		end
	end,
})
