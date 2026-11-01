-- oxfmt の設定ファイル。conform の oxfmt の cwd は vite.config.* も root の目印にするので、
-- require_cwd だけだと oxfmt を使わない vite のプロジェクトで oxfmt が選ばれ、毎回 WARN が出る
local oxfmt_configs = { ".oxfmtrc.json", ".oxfmtrc.jsonc", "oxfmt.config.ts" }

local js_like = { "oxfmt", "biome", "prettier", stop_after_first = true }

return {
  {
    "stevearc/conform.nvim",
    cmd = { "ConformInfo" },
    keys = {
      {
        "<leader>cf",
        function()
          require("conform").format({ async = true, lsp_format = "fallback" })
        end,
        mode = { "n", "v" },
        desc = "Format",
      },
    },
    -- 保存時の整形はしない（format_on_save を設定しない）
    opts = {
      formatters_by_ft = {
        lua = { "stylua" },
        sh = { "shfmt" },
        bash = { "shfmt" },
        python = { "ruff_format" },
        markdown = { "prettier" },
        javascript = js_like,
        javascriptreact = js_like,
        typescript = js_like,
        typescriptreact = js_like,
        json = js_like,
        jsonc = js_like,
      },
      formatters = {
        oxfmt = {
          condition = function(_, ctx)
            return vim.fs.find(oxfmt_configs, { path = ctx.filename, upward = true })[1] ~= nil
          end,
        },
        biome = { require_cwd = true },
      },
    },
  },
}
