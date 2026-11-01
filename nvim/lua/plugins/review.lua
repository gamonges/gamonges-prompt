-- 既定のブランチ（origin/HEAD の先）。今のバッファの repo で引き、取れなければ知らせて origin/main に倒す
local function default_branch()
  local dir = vim.fs.dirname(vim.api.nvim_buf_get_name(0))
  local cwd = (dir and vim.fn.isdirectory(dir) == 1) and dir or vim.fn.getcwd()
  -- stdout だけを読む（systemlist は stderr を混ぜる）。git が無いと vim.system は例外を投げる
  local ok, res = pcall(function()
    return vim.system({ "git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, { cwd = cwd, text = true })
      :wait()
  end)
  local branch = ok and res.code == 0 and vim.trim(res.stdout or "") or ""
  if branch ~= "" then
    return branch
  end
  vim.notify("既定のブランチ（origin/HEAD）を読めないので origin/main と比べます", vim.log.levels.WARN)
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
