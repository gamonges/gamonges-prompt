# Neovim の設定

`./setup.sh install` が `~/.config/nvim` をこのディレクトリへの symlink にする（既存の実ディレクトリ・他所へのリンクは `~/.config/nvim.pre-install.<日時>-<PID>` に退避）。プラグインは lazy.nvim が管理し、版は `lazy-lock.json` に固定する。

## 必要なツール

LSP サーバとフォーマッタは mise でグローバルに入れる（mise の設定は repo の外の `~/.config/mise/config.toml`）。

| 言語 | LSP | フォーマッタ・lint | mise での指定 |
|------|-----|-------------------|--------------|
| TS / JS | ts_ls | プロジェクトの node_modules（oxfmt・biome・prettier・oxlint） | `npm:typescript-language-server`・`npm:typescript` |
| Lua | lua_ls | stylua | `lua-language-server`・`stylua` |
| Shell | bashls | shfmt・shellcheck（bashls が呼ぶ） | `npm:bash-language-server`・`shfmt`・`shellcheck` |
| Markdown | marksman | prettier | `marksman`・`npm:prettier` |
| Python | basedpyright | ruff（LSP と整形） | `npm:basedpyright`・`ruff` |

```bash
mise use -g npm:typescript-language-server npm:typescript lua-language-server stylua \
  npm:bash-language-server shfmt shellcheck marksman npm:prettier npm:basedpyright ruff
```

## LSP と整形の振る舞い

- LSP のキーは Neovim 0.12 の既定（`K` 型・ドキュメント、`grn` 名前の変更、`gra` code action、`grr` 参照、`gri` 実装、`grt` 型定義、`grx` codelens、`gO` シンボル、`[d` / `]d` 診断）
- `<leader>cf` で整形する。**保存では整形しない**
- TS / JS / JSON の整形は、プロジェクトの設定に従って最初に使えるものを選ぶ: oxfmt（`.oxfmtrc.json`・`.oxfmtrc.jsonc`・`oxfmt.config.ts` がある）→ biome（`biome.json` がある）→ prettier
- 次の LSP は、起動に要る実体がプロジェクトにあるときだけ起動する（無いと起動に失敗し、開くたびにエラーが出るため）
  - ts_ls: root から上のどこかに `node_modules/typescript/lib/tsserver.js` がある。**プロジェクトの外の `.ts` では起動しない**（グローバルの `typescript@7` はネイティブ版で tsserver を持たない）
  - oxlint・biome: 設定のあるプロジェクトの `node_modules/.bin/` に実体がある。`npm install` の前は起動しない
- 選ばれたフォーマッタは `:ConformInfo`、attach した LSP は `:checkhealth vim.lsp` で見る

## PR のレビュー（atlas.nvim）

- `<leader>gd`: `:Atlas diff <既定のブランチ>...HEAD`（自分の変更）。`<leader>gp`: `:Atlas review`（今の repo の open な PR を選ぶ。番号を指定するなら `:Atlas review <番号>`）
- 差分は一時 worktree（`~/.cache/nvim/atlas/worktrees/`）に開き、作業中の worktree の branch と未コミットの変更は変えない。差分のタブを閉じる（または nvim を終える）と一時 worktree は消える
- 一時 worktree では LSP が動き、`node_modules` は手元のチェックアウトから symlink する
- `<leader>gh`: 今のファイルの履歴（fugitive の `:0Gclog`。atlas にファイル単位の履歴は無い）
- 差分のバッファの中では、atlas のキー（`<leader>gs` レビューの送信・`<leader>ga` Approve・`<leader>gr` Request changes・`<leader>n` note・`<leader>f`・`<leader>e`・`<leader>b`・`<leader>t`）が全体のキーより優先される
- **改名した repo は origin を新しい名前に直す**: atlas は手元のチェックアウトの origin の `owner/name` が PR の repo と一致するときだけそれを使う。一致しないと自前の clone（`~/.cache/nvim/atlas/repos/`）に開き、そこには `node_modules` が無いので LSP が起動しない。`gh repo view --json nameWithOwner` の名前に `git remote set-url origin …` で合わせる

## 試行（本番の設定を変えずに試す）

worktree の設定を本番の `~/.config/nvim` と分けて試すには、別の `NVIM_APPNAME` を使う。プラグイン・データ・キャッシュも `nvim-pr` の下に分かれる。

```bash
ln -s <worktree>/nvim ~/.config/nvim-pr
NVIM_APPNAME=nvim-pr nvim
# 終わったら
rm ~/.config/nvim-pr
```
