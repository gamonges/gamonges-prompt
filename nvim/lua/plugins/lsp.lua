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
      local function has_tsserver(root)
        for dir in vim.fs.parents(vim.fs.joinpath(root, "x")) do
          if vim.uv.fs_stat(vim.fs.joinpath(dir, "node_modules/typescript/lib/tsserver.js")) then
            return true
          end
        end
        return false
      end
      start_only_if("ts_ls", has_tsserver)
      -- TypeScript 7 は tsserver.js を持たず、tsc 自身が LSP になる（tsc --lsp）。ts_ls が起動しないときだけ使う。
      -- ts_ls と tsc は同じ規則（lock ファイル）で root を決めるので、同じ root で判定すれば両方つくことはない。
      -- 一時 worktree（atlas）のようにプロジェクトの tsc が見えなくても、tsc は PATH の版で起動する
      -- lspconfig の root_dir より先に判定する: lspconfig の root_dir は TS 7 の tsc が見つからないと WARN を出すので、
      -- 後で判定すると ts_ls のプロジェクトで開くたびに WARN が出る。root は lspconfig の ts_ls・tsc と同じ規則で引く
      local orig_tsc_root_dir = vim.lsp.config.tsc.root_dir
      vim.lsp.config("tsc", {
        root_dir = function(bufnr, on_dir)
          local lockfiles = { "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock" }
          local root = vim.fs.root(bufnr, { lockfiles, { ".git" } }) or vim.fn.getcwd()
          if not has_tsserver(root) then
            orig_tsc_root_dir(bufnr, on_dir)
          end
        end,
      })

      vim.lsp.enable({ "ts_ls", "tsc", "lua_ls", "bashls", "marksman", "basedpyright", "ruff", "oxlint", "biome", "prismals" })
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
