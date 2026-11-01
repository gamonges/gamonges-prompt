local map = vim.keymap.set

-- Window navigation
map("n", "<C-h>", "<C-w>h", { desc = "Move to left window" })
map("n", "<C-j>", "<C-w>j", { desc = "Move to lower window" })
map("n", "<C-k>", "<C-w>k", { desc = "Move to upper window" })
map("n", "<C-l>", "<C-w>l", { desc = "Move to right window" })

-- Buffer navigation
map("n", "<Tab>", "<cmd>bnext<cr>", { desc = "Next buffer" })
map("n", "<S-Tab>", "<cmd>bprevious<cr>", { desc = "Previous buffer" })

-- Clear search highlight
map("n", "<Esc>", "<cmd>nohlsearch<cr>", { desc = "Clear search highlight" })

-- Better vertical movement (centered)
map("n", "<C-d>", "<C-d>zz", { desc = "Scroll down (centered)" })
map("n", "<C-u>", "<C-u>zz", { desc = "Scroll up (centered)" })

-- Quick access to tmp/ files (Claude Code workflow)
map("n", "<leader>tp", "<cmd>edit tmp/plan.md<cr>", { desc = "Open plan" })
map("n", "<leader>tr", "<cmd>edit tmp/research.md<cr>", { desc = "Open research" })
map("n", "<leader>tl", "<cmd>edit tmp/lessons.md<cr>", { desc = "Open lessons" })
map("n", "<leader>tc", "<cmd>edit tmp/context.md<cr>", { desc = "Open context" })

-- Command-line abbreviations (user commands must start uppercase, so short lowercase names need cabbrev).
-- Expand only when the whole ":" cmdline is the abbreviation; otherwise "/at" or ":echo at" would expand too.
local function cabbrev(lhs, rhs)
  map("ca", lhs, function()
    return (vim.fn.getcmdtype() == ":" and vim.fn.getcmdline() == lhs) and rhs or lhs
  end, { expr = true, desc = ":" .. lhs .. " -> :" .. rhs })
end
cabbrev("mp", "MarkdownPreviewToggle")
cabbrev("at", "Atlas")

-- Key cheatsheet (cheatsheet.md in this config)
map("n", "<leader>?", function()
  require("config.cheatsheet").toggle()
end, { desc = "Cheatsheet" })
