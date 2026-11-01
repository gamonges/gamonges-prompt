-- Orca の別のペインで動く Claude Code に、今のファイル・選択を渡す（Claude 側で /ide を打って繋ぐ）。
-- nvim の中で claude は動かさない（terminal.provider = "none"）ので、snacks.nvim は要らない

-- 接続口（WebSocket サーバと lock）を開く nvim かどうか。opts の評価時に 1 回だけ呼ばれる。
-- 開かない nvim でも claudecode は読み込まれ、送信キーは「integration is not running」の ERROR を 1 回出すだけ
local function should_auto_start()
  -- TODO(ユーザー): Claude の外部エディタ（ctrl+g）と git の一時ファイル（COMMIT_EDITMSG など）で開いた nvim では false を返す。
  -- 材料は vim.env と vim.fn.argv() だけ（ゲート G-5 で、ctrl+g の nvim に CLAUDECODE が立つかを確かめてから決める）
  return true
end

-- 送る参照は送信時の getcwd() 基準の相対パスになり、Claude は自分の cwd（＝ nvim の全体の cwd）で解決する。
-- atlas のタブは tcd で一時 worktree にいるので、送る間だけ全体の cwd に替えて整形させる
local function run_from_global_cwd(cmd)
  local win_cwd = vim.fn.getcwd()
  local global_cwd = vim.fn.getcwd(-1, -1)
  local claudecode = require("claudecode")
  -- 接続口が無いときは claudecode 自身の ERROR に任せる
  if win_cwd == global_cwd or not claudecode.state.server then
    vim.cmd(cmd)
    return
  end
  -- 未接続の送信は待ち行列に積まれ、繋がった後に整形される。そのときには cwd が戻っていて、
  -- 一時 worktree 基準のパスで手元のブランチの版を読ませてしまうので、送らない
  if not claudecode.is_claude_connected() then
    vim.notify(
      "Claude に未接続のため送りません（このタブの cwd では参照のパスがずれます）。/ide で繋いでから送り直してください",
      vim.log.levels.WARN
    )
    return
  end
  -- ウィンドウの lcd が無ければタブの tcd で戻す（tcd はウィンドウの lcd も外す）
  local restore = vim.fn.haslocaldir(0, 0) == 1 and "lcd" or "tcd"
  vim.cmd("noautocmd lcd " .. vim.fn.fnameescape(global_cwd))
  -- 接続済みの送信は整形まで同期なので、戻す前に終わっている
  local ok, err = pcall(vim.cmd, cmd)
  vim.cmd("noautocmd " .. restore .. " " .. vim.fn.fnameescape(win_cwd))
  if not ok then
    vim.notify(tostring(err), vim.log.levels.ERROR)
  end
end

local function send_selection()
  -- ビジュアルモードのまま ClaudeCodeSend を呼ぶと処理が vim.schedule で後回しになり、cwd を戻した後に整形される。
  -- :normal! で同期的に抜けて '< '> を確定させ、範囲付きで呼ぶ（feedkeys は非同期なので使えない）
  vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
  run_from_global_cwd("'<,'>ClaudeCodeSend")
end

return {
  -- rhs の無い lazy の keys は読み込み後に消えるので、グループ名は which-key に直接渡す（opts は spec をまたいでマージされる）
  { "folke/which-key.nvim", opts = { spec = { { "<leader>a", group = "AI/Claude Code" } } } },
  {
    "coder/claudecode.nvim",
    -- 接続口は setup() で開くので、cmd・keys だけの遅延読み込みにすると、キーを押すまで /ide の候補に出ない
    event = "VeryLazy",
    keys = {
      -- select モードに張ると、スニペットの置き換えで <leader> を打てなくなるので x
      { "<leader>as", send_selection, mode = "x", desc = "Send selection to Claude" },
      {
        "<leader>ab",
        function()
          run_from_global_cwd("ClaudeCodeAdd %")
        end,
        desc = "Add buffer to Claude",
      },
      -- neo-tree は atlas のタブで使わない（ウィンドウの cwd ＝ 全体の cwd）ので包まない
      { "<leader>as", "<cmd>ClaudeCodeTreeAdd<cr>", desc = "Add file to Claude", ft = { "neo-tree" } },
      { "<leader>ai", "<cmd>ClaudeCodeStatus<cr>", desc = "Claude connection status" },
    },
    opts = {
      terminal = { provider = "none" },
      auto_start = should_auto_start(),
    },
  },
}
