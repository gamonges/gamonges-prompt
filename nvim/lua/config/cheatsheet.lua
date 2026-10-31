-- キーのチートシート（stdpath("config")/cheatsheet.md）をフロートで開閉する。
-- 場所を stdpath で引くのは、試行用の NVIM_APPNAME でも本番でも、それぞれの設定のシートを開くため
local M = {}

local win

function M.toggle()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, false)
    win = nil
    return
  end

  local path = vim.fn.stdpath("config") .. "/cheatsheet.md"
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = false

  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor((vim.o.lines - vim.o.cmdheight) * 0.8)
  win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    border = "rounded",
    title = " Cheatsheet ",
    title_pos = "center",
  })

  -- <Esc> は使わない。normal の <Esc> は検索のハイライトを消すキーで、シートの中でも使いたいため。
  -- シートは編集できるまま（覚えたら消し、知ったら書き足す。保存は :w）
  vim.keymap.set("n", "q", M.toggle, { buffer = buf, nowait = true, desc = "Close cheatsheet" })
end

return M
