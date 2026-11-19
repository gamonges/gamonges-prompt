# tsgo-lsp

TypeScript 7（typescript-go）の内蔵 LSP（`tsc --lsp --stdio`）を Claude Code の code intelligence として使うプラグイン。公式の `typescript-lsp`（typescript-language-server）は TS 7 に `tsserver.js` が無いため起動しない。

## インストール

```bash
claude plugin marketplace add ~/workspaces/gamonges-prompt/claude/plugins
claude plugin install tsgo-lsp@gamonges
claude plugin disable typescript-lsp@claude-plugins-official   # 同じ拡張子を取り合わないように止める
```

## 中継が要る理由

Claude Code は診断を push（`textDocument/publishDiagnostics`）でしか受けないが、TS 7.0 は開いたファイルの診断を pull（`textDocument/diagnostic`）でしか返さない。`bin/tsgo-lsp-proxy.mjs` が didOpen / didChange / didSave を見て pull を投げ、結果を push に変えて返す。上流で push が入れば（microsoft/TypeScript#63921）中継は要らなくなる。

## 前提

- TypeScript 7 の `tsc`。`mise where npm:typescript@7` → PATH の `tsc` の順で探し、`--version` が 7 以上のものを使う。PATH の `tsc` は repo の mise 設定で別の版になりうるので、見つからなければ `TSGO_LSP_COMMAND` で指定する
- Node.js（中継の実行に使う）

## 環境変数

| 変数 | 既定 | 意味 |
|---|---|---|
| `TSGO_LSP_COMMAND` | 自動で探す | 起動する TS 7 の `tsc` |
| `TSGO_LSP_PULL_SCOPE` | `changed` | `changed` は変更したファイルだけ、`all` は開いている全件を引き直す（import 先の変更も拾うが重い） |
| `TSGO_LSP_DEBOUNCE` | `150` | 変更から pull までの待ち（ms） |
| `TSGO_LSP_ALLOW` | なし | `1` なら下の起動停止を無視する |
| `TSGO_LSP_DEBUG` | なし | `1` なら中継の動きを stderr に出す |

## 大きな repo での起動停止

TS 7 の LSP は開いたファイルの tsconfig 全体を読み込み、大きな repo では LSP だけで数 GB を常に使う（checker 数は 4 で固定、`GOMEMLIMIT` / `GOGC` では減らなかった）。`~/.config/tsgo-lsp/deny-roots`（`XDG_CONFIG_HOME` があればその下）に書いた場所では tsc を起動せず、空で答える LSP として振る舞う。許可するときは `TSGO_LSP_ALLOW=1 claude` で起動する。

```
# 1 行 1 件。# 以降はコメント
# / か ~ で始まればパスの前方一致、それ以外はディレクトリ名との一致
some-large-repo
~/work/another-repo
```

## 既知の制約

- 空の診断は Claude Code が捨てる（anthropics/claude-code#100569）ので、エラーが直ったことはモデルに届かない
- `changed` では、import 先の変更で別ファイルに出た型エラーは、そのファイルを次に触るまで更新されない
- 診断は Edit の結果には間に合わず、次のツール呼び出しの回でモデルに渡る（Claude Code は Edit の直後に診断を待たない。anthropics/claude-code#93321）。Edit だけで答えを終えると届かない
