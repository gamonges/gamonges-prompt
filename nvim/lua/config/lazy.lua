local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local out = vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    lazypath,
  })
  if vim.v.shell_error ~= 0 then
    -- 途中まで作られたディレクトリが残ると、次の起動は clone を飛ばして require("lazy") で落ちる
    vim.fn.delete(lazypath, "rf")
    vim.api.nvim_echo({ { "lazy.nvim の clone に失敗しました:\n" .. out, "ErrorMsg" } }, true, {})
    return
  end
  -- bootstrap した lazy.nvim は lazy 自身の restore の対象外で、clone した版が lockfile に書き戻される。
  -- lockfile の版はここで合わせる
  local ok, lock = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lazy-lock.json"), "\n"))
  end)
  local commit = ok and type(lock) == "table" and type(lock["lazy.nvim"]) == "table" and lock["lazy.nvim"].commit
  if commit then
    vim.fn.system({ "git", "-C", lazypath, "checkout", "-q", commit })
  end
  if not commit or vim.v.shell_error ~= 0 then
    vim.notify("lazy.nvim を lazy-lock.json の版に合わせられませんでした（clone した版のまま）", vim.log.levels.WARN)
  end
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup("plugins", {
  defaults = { lazy = true },
  checker = { enabled = false },
  change_detection = { notify = false },
})
