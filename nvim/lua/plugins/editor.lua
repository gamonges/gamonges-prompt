return {
  -- Fuzzy finder
  {
    "nvim-telescope/telescope.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
      {
        "nvim-telescope/telescope-fzf-native.nvim",
        build = "make",
      },
    },
    cmd = "Telescope",
    keys = {
      { "<leader>ff", "<cmd>Telescope find_files<cr>", desc = "Find files" },
      { "<leader>fg", "<cmd>Telescope live_grep<cr>", desc = "Live grep" },
      { "<leader>fb", "<cmd>Telescope buffers<cr>", desc = "Buffers" },
      { "<leader>fr", "<cmd>Telescope oldfiles<cr>", desc = "Recent files" },
      { "<leader>fh", "<cmd>Telescope help_tags<cr>", desc = "Help tags" },
    },
    config = function()
      local telescope = require("telescope")
      telescope.setup({
        defaults = {
          file_ignore_patterns = { "node_modules", ".git/" },
        },
      })
      pcall(telescope.load_extension, "fzf")
    end,
  },

  -- File tree
  {
    "nvim-neo-tree/neo-tree.nvim",
    branch = "v3.x",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-tree/nvim-web-devicons",
      "MunifTanjim/nui.nvim",
    },
    keys = {
      { "<leader>e", "<cmd>Neotree toggle<cr>", desc = "File tree" },
    },
    opts = {
      filesystem = {
        follow_current_file = { enabled = true },
      },
    },
  },

  -- Keymap help
  {
    "folke/which-key.nvim",
    event = "VeryLazy",
    opts = {},
  },

  -- Treesitter (syntax highlighting foundation)
  -- Neovim 0.11+ uses the main branch (full rewrite)
  {
    "nvim-treesitter/nvim-treesitter",
    lazy = false,
    build = ":TSUpdate",
    config = function()
      require("nvim-treesitter").setup()

      -- Install parsers
      require("nvim-treesitter").install({
        "markdown",
        "markdown_inline",
        "lua",
        "vim",
        "vimdoc",
        "query",
        "bash",
        "python",
        "javascript",
        "typescript",
        "tsx",
        "json",
      })

      -- Enable treesitter highlighting for all supported filetypes
      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("treesitter_start", { clear = true }),
        callback = function()
          pcall(vim.treesitter.start)
        end,
      })
    end,
  },
}
