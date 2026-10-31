return {
  -- LSP の設定集。サーバ本体は mise で入れる（nvim/README.md）。キーは 0.12 の既定（K・grn・gra・grr・gri・grt・grx・gO）を使う
  {
    "neovim/nvim-lspconfig",
    event = { "BufReadPre", "BufNewFile" },
    -- blink は自分の plugin/ で vim.lsp.config('*', { capabilities = … }) を実行する。
    -- LSP より後に読むと、先に起動したクライアントが補完の capabilities を持たない
    dependencies = { "saghen/blink.cmp" },
    config = function()
      vim.lsp.config("lua_ls", {
        settings = {
          Lua = {
            runtime = { version = "LuaJIT" },
            workspace = {
              checkThirdParty = false,
              library = { vim.env.VIMRUNTIME },
            },
          },
        },
      })
      -- lspconfig の oxlint は設定ファイルが無くても root 無しで起動しうる。設定のあるプロジェクトでだけ動かす
      -- （biome は lspconfig 側で workspace_required = true が既にある）
      vim.lsp.config("oxlint", { workspace_required = true })

      -- root は見つかっても、起動に要る実体がプロジェクトに無いと起動に失敗し、開くたびにエラーが出る
      -- （package.json のスクリプトに `pnpm dlx oxlint` があるだけで oxlint の root になる。
      -- グローバルの oxlint・biome は入れず、グローバルの typescript@7 は tsserver を持たない）。
      -- 実体があるときだけ lspconfig の root_dir の結果を渡す
      local function start_only_if(name, has_runtime)
        local orig = vim.lsp.config[name].root_dir
        vim.lsp.config(name, {
          root_dir = function(bufnr, on_dir)
            orig(bufnr, function(root)
              if root and has_runtime(root) then
                on_dir(root)
              end
            end)
          end,
        })
      end
      local function local_bin(bin)
        return function(root)
          return vim.fn.executable(vim.fs.joinpath(root, "node_modules/.bin", bin)) == 1
        end
      end
      start_only_if("oxlint", local_bin("oxlint"))
      start_only_if("biome", local_bin("biome"))
      -- typescript は monorepo の上位に hoist されうるので、root から上へ探す
      start_only_if("ts_ls", function(root)
        for dir in vim.fs.parents(vim.fs.joinpath(root, "x")) do
          if vim.uv.fs_stat(vim.fs.joinpath(dir, "node_modules/typescript/lib/tsserver.js")) then
            return true
          end
        end
        return false
      end)

      vim.lsp.enable({ "ts_ls", "lua_ls", "bashls", "marksman", "basedpyright", "ruff", "oxlint", "biome" })
    end,
  },

  -- 補完
  {
    "saghen/blink.cmp",
    -- 1.* はプリビルドのバイナリを取る
    version = "1.*",
    opts = {
      -- 確定は <C-y>。<Tab> は insert モードのスニペットの移動だけで、通常モードの <Tab>（bnext）とは衝突しない
      keymap = { preset = "default" },
    },
  },
}
