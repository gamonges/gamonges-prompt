-- Leader key (must be set before lazy.nvim)
vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- Line numbers
vim.opt.number = true
vim.opt.relativenumber = true

-- Indentation
vim.opt.expandtab = true
vim.opt.shiftwidth = 2
vim.opt.tabstop = 2
vim.opt.softtabstop = 2
vim.opt.smartindent = true

-- Search
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.hlsearch = true
vim.opt.incsearch = true

-- Clipboard
vim.opt.clipboard = "unnamedplus"

-- Undo persistence
vim.opt.undofile = true
vim.opt.undodir = vim.fn.stdpath("state") .. "/undo"

-- UI
vim.opt.termguicolors = true
vim.opt.signcolumn = "yes"
vim.opt.cursorline = true
vim.opt.scrolloff = 8
vim.opt.sidescrolloff = 8

-- Split behavior
vim.opt.splitbelow = true
vim.opt.splitright = true

-- File handling
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.fileencoding = "utf-8"

-- Update time (for gitsigns etc.)
vim.opt.updatetime = 250
vim.opt.timeoutlen = 300

-- 保存前にディレクトリを自動作成する
vim.api.nvim_create_autocmd("BufWritePre", {
  group = vim.api.nvim_create_augroup("AutoCreateDir", { clear = true }),
  callback = function(args)
    -- フルパスを取得
    local file = args.match
    if file == "" then
      return
    end

    -- 親ディレクトリを取得
    local dir = vim.fn.fnamemodify(file, ":p:h")

    -- ディレクトリが無ければ作成
    if vim.fn.isdirectory(dir) == 0 then
      vim.fn.mkdir(dir, "p")
    end
  end,
})

