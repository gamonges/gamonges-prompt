-- 既定のブランチ（origin/HEAD の先）。取れなければ origin/main
local function default_branch()
  local out = vim.fn.systemlist({ "git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD" })
  if vim.v.shell_error == 0 and out[1] and out[1] ~= "" then
    return out[1]
  end
  return "origin/main"
end

return {
  -- PR のレビュー（自分の PR は :Atlas diff、他者の PR は :Atlas review）。
  -- 差分は一時 worktree に開くので、作業中の worktree の branch と未コミットの変更は変わらない
  {
    "emrearmagan/atlas.nvim",
    -- plugin/atlas.lua は vim.g.loaded_atlas を立てるだけで、:Atlas は setup() が作る
    cmd = "Atlas",
    keys = {
      {
        "<leader>gd",
        function()
          -- :Atlas diff は三点の base...head だけを受け付ける
          vim.cmd("Atlas diff " .. default_branch() .. "...HEAD")
        end,
        desc = "Atlas diff (default branch...HEAD)",
      },
      { "<leader>gp", "<cmd>Atlas review<cr>", desc = "Atlas review (pick a PR)" },
    },
    opts = {
      -- 既定値に providers が無く、無いと「provider not configured」で止まる
      providers = { github = {} },
      -- 有効だと atlas が laststatus = 3 を強制し、lualine の表示が変わる
      ui = { statusline = { atlas = false, diff = false } },
      pulls = {
        diff = {
          -- 既定の "auto" は :CodeDiff・:DiffviewOpen があればそちらを選び、LSP の worktree が作られない
          open_cmd = "AtlasDiff",
          -- 一時 worktree で LSP を動かす。node_modules は元の worktree から symlink する
          lsp = { enabled = true, link = { "node_modules" } },
        },
      },
    },
  },
}
