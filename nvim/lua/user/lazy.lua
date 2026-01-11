local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  { 'projekt0n/github-nvim-theme', name = 'github-theme' },

  {
    "nvim-treesitter/nvim-treesitter", branch = 'master', lazy = false, build = ":TSUpdate",
    config = function()
      require('nvim-treesitter.configs').setup({
      ensure_installed = { 'typescript', 'tsx' },
      highlight = {
        enable = true,
      },
    })
    end,
  },

  {
    'nvim-telescope/telescope.nvim', tag = '0.1.8',
    dependencies = { 'nvim-lua/plenary.nvim' },
  },

  {
    "pmizio/typescript-tools.nvim",
    dependencies = { "nvim-lua/plenary.nvim", "neovim/nvim-lspconfig" },
    opts = {},
  },

  { "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = { theme = "github-theme" }
  },

  { "famiu/bufdelete.nvim" },

  {
    'ggml-org/llama.vim',
      init = function()
        vim.g.llama_config = {

        -- Keybindings
        keymap_accept_full = "<C-CR>",
        keymap_accept_line = "<S-CR>",
        keymap_accept_word = "<Nop>",
        keymap_trigger = "<Nop>",

        -- Disable verbose logging
        show_info = 1,
      }
     end,
  },

  {
    'mrcjkb/rustaceanvim',
    version = '^6',
    lazy = false, -- This plugin is already lazy
  },

  {
    "neovim/nvim-lspconfig",
    event = { "BufReadPre", "BufNewFile" },
    dependencies = {
      "hrsh7th/nvim-cmp",
      "hrsh7th/cmp-nvim-lsp",
      "L3MON4D3/LuaSnip",
    },
    config = function()
      local cmp = require("cmp")
      
      local capabilities = vim.lsp.protocol.make_client_capabilities()
      capabilities = require("cmp_nvim_lsp").default_capabilities(capabilities)

      cmp.setup({
        snippet = { expand = function(args) require("luasnip").lsp_expand(args.body) end },
        mapping = cmp.mapping.preset.insert({
          ["<C-Space>"] = cmp.mapping.complete(),
          ["<CR>"] = cmp.mapping.confirm({ select = true }),
          ["<C-f>"] = cmp.mapping.scroll_docs(4),
          ["<C-b>"] = cmp.mapping.scroll_docs(-4),
        }),
        sources = { { name = "nvim_lsp" }, { name = "luasnip" } },
      })

      local on_attach = function(client, bufnr)
        local map = vim.keymap.set
        local opts = { buffer = bufnr, silent = true, noremap = true }
        map("n", "gd", vim.lsp.buf.definition, opts)
        map("n", "K", vim.lsp.buf.hover, opts)
        map("n", "gi", vim.lsp.buf.implementation, opts)
        map("n", "gr", vim.lsp.buf.references, opts)
        map("n", "<leader>rn", vim.lsp.buf.rename, opts)
        map("n", "<leader>f", function() vim.lsp.buf.format({ async = true }) end, opts)
      end

      vim.lsp.config('clangd', {
        on_attach = on_attach,
        capabilities = capabilities,
      })
    end,
  },
})
