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

-- Jump from a TS type name to its Prisma schema definition (enum / model / type / view).
-- No LSP links TS to .prisma; the generated client reuses the schema's names, so match by name.
-- Search tracked files with git grep: the generated client is gitignored and absent in atlas's temp worktree.
local function prisma_definition()
  local name = vim.fn.expand("<cword>")
  if not name:match("^[%a_][%w_]*$") then
    vim.notify("カーソルの下に名前がありません", vim.log.levels.WARN)
    return
  end
  -- atlas's diff buffers are not files; fall back to cwd (the diff tab is tcd'd to the temp worktree)
  local root = vim.fs.root(0, ".git") or vim.fs.root(vim.fn.getcwd(), ".git")
  if not root then
    vim.notify("git の repo の外です", vim.log.levels.WARN)
    return
  end
  local pattern = "^[[:space:]]*(enum|model|type|view)[[:space:]]+" .. name .. "[[:space:]]*\\{"
  local res = vim.system({ "git", "grep", "-n", "--column", "-E", pattern, "--", "*.prisma" }, { cwd = root, text = true }):wait()
  local items = {}
  for line in (res.stdout or ""):gmatch("[^\n]+") do
    local file, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
    if file then
      table.insert(items, { filename = vim.fs.joinpath(root, file), lnum = tonumber(lnum), col = tonumber(col), text = text })
    end
  end
  if #items == 0 then
    vim.notify(("Prisma に %s の定義はありません"):format(name), vim.log.levels.WARN)
  elseif #items == 1 then
    vim.cmd("normal! m'")
    -- Don't replace a special buffer (atlas's diff) in place; open the schema in a new tab like atlas's gf
    vim.cmd((vim.bo.buftype == "" and "edit " or "tabedit ") .. vim.fn.fnameescape(items[1].filename))
    vim.api.nvim_win_set_cursor(0, { items[1].lnum, items[1].col - 1 })
  else
    vim.fn.setqflist({}, " ", { title = "Prisma: " .. name, items = items })
    vim.cmd("copen")
  end
end
map("n", "<leader>prismad", prisma_definition, { desc = "Go to Prisma definition" })

-- Key cheatsheet (cheatsheet.md in this config)
map("n", "<leader>?", function()
  require("config.cheatsheet").toggle()
end, { desc = "Cheatsheet" })
