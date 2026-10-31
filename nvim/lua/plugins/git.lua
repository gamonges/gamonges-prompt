return {
  -- Git signs in sign column
  {
    "lewis6991/gitsigns.nvim",
    event = { "BufReadPre", "BufNewFile" },
    opts = {},
  },

  -- Git commands
  {
    "tpope/vim-fugitive",
    cmd = { "Git", "Gvdiffsplit", "Gdiffsplit", "Gclog" },
    keys = {
      { "<leader>gs", "<cmd>Git<cr>", desc = "Git status" },
      { "<leader>gb", "<cmd>Git blame<cr>", desc = "Git blame" },
      { "<leader>gl", "<cmd>Git log --oneline<cr>", desc = "Git log" },
      -- 今のファイルの履歴（quickfix）。atlas にはファイル単位の履歴が無い
      { "<leader>gh", "<cmd>0Gclog<cr>", desc = "File history" },
    },
  },
}
