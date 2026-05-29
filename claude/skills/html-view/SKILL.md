---
name: html-view
description: |
  Markdown ドキュメント (plan / fix-plan / review / research) を Claude 自身が読んで人間レビュア向けのデザイン HTML に変換する。
  PdM/SRE への共有時、ブラウザでデザインプレビューを開きたい時、`/html-view <file.md>` のキーワードで使用。
---

**規約**: CLAUDE.md の Skills 共通規約に従う

入力 Markdown を Claude (本セッション) 自身が読み込み、ドキュメント種別に応じた prompt + 参照 example HTML を文脈にして単体完結 HTML を組み立てる。生成 HTML は `tmp/` 配下に Write し、`--no-open` 指定がない限りブラウザで自動起動する。Python script は使わない (LLM 直接生成方式)。

## パラメーター

```
/html-view <input.md> [--style auto|review|plan|fix-plan|research|generic] [--output <path.html>] [--no-open]
```

- `<input.md>`: 変換対象 Markdown ファイル (必須)
- `--style auto`: 構造を自動判定 (デフォルト)。明示指定で判定をスキップ (token 削減)
  - `review`: 指摘対象 → 問題 → 修正案 の流れ、severity badge
  - `plan`: アーキテクチャ概要 + レイヤー別 details/タブ + ステップカード
  - `fix-plan`: 問題 ↔ 修正の対比カラム、優先度 badge、Round タイムライン
  - `research`: Q&A 構造、情報量に応じてサイドバー or CSS-only タブ or 折りたたみ
  - `generic`: 標準 markdown スタイル (該当 style 無しの自動フォールバック)
- `--output`: 出力先パス (デフォルト: `tmp/{basename}.html`、現ディレクトリ基準)
- `--no-open`: ブラウザ自動起動を抑制 (CI / SSH 環境用)

## ワークフロー上の位置付け

| 前工程 | 本コマンド | 後工程 |
|--------|-----------|--------|
| `/ask` `/design` `/review` `/fix` の完了報告で「HTML 化しますか?」プロンプト | `/html-view <出力ファイル>` | (ブラウザで人間レビュー) |

本コマンドは独立して呼び出してもよい (任意の Markdown を HTML 化する用途)。Claude による自動チェイン実行はしない (オプトイン運用)。

## 実行条件

- 入力 `<input.md>` が存在すること
- `~/.claude/skills/html-view/reference/prompts/{review,plan,fix-plan,research,generic}-style.md` のうち、判定された style 用ファイルが存在する
- `~/.claude/skills/html-view/reference/style-guide.md` が存在する
- `~/.claude/skills/html-view/reference/examples/*.html` の参照例が存在する

いずれかが満たされない場合は処理を即停止しユーザーに報告する。

## 実行プロセス

### フェーズ 1: 入力検証

- [ ] `$ARGUMENTS` から `<input.md>` とオプションを取得
- [ ] 入力ファイルが存在しなければ即停止
- [ ] `--style` が指定されていれば有効な値か (`auto|review|plan|fix-plan|research|generic`) チェック。不正なら警告して `auto` で続行

### フェーズ 2: 種別判定

`--style auto` の場合、以下の優先順で判定する:

1. **ファイル名による判定** (高速、token ゼロ):
   - `*fix-plan*.md` → `fix-plan`
   - `*plan*.md` (fix-plan を除く) → `plan`
   - `*research*.md` → `research`
   - `unified.md` または `*review*.md` → `review`
2. **構造ヒューリスティック** (ファイル名で決まらない場合、Read で本文先頭 100 行を確認):
   - `^##\s+(❌\s*)?Critical` または `^##\s+(⚠️\s*)?Minor` を含む → `review`
   - `^##\s+実装ステップ` + `^###\s+ステップ` + (「現状の問題」または「修正方針」見出し) → `fix-plan`
   - `^##\s+実装ステップ` + `^###\s+ステップ` → `plan`
   - `^##\s+質問` または `^###?\s+回答` → `research`
3. **いずれにも該当しない場合**: `generic` にフォールバック + 「style を auto 判定できなかったため generic を使用」と console に警告 (Q-A 暫定方針)

`--style` 明示指定時は本フェーズを skip (コスト削減策 #2)。

### フェーズ 3: コンテキスト読込

判定された style に応じて以下を Read する:

1. `~/.claude/skills/html-view/reference/prompts/{style}-style.md` — 種別固有のデザイン指示 + 必須要素チェックリスト
2. `~/.claude/skills/html-view/reference/style-guide.md` — 共通 CSS 変数 / フォント / レスポンシブ / `@media print` / 単体完結原則
3. 該当 example HTML を Read:
   - `fix-plan` style: `~/.claude/skills/html-view/reference/examples/fix-plan.html`
   - `plan` style: `~/.claude/skills/html-view/reference/examples/adr-pipeline.html` (+ レイヤー別タブが必要な場合のみ `css-tabs.html`)
   - `review` style: `~/.claude/skills/html-view/reference/examples/fix-plan.html` (カードレイアウト流用)
   - `research` style: `~/.claude/skills/html-view/reference/examples/adr-pipeline.html` + (情報量多 → `css-tabs.html`)
   - `generic` style: example 不要
4. 入力 `<input.md>` を Read

### フェーズ 4: HTML 組み立て

読み込んだ文脈で Claude (本セッション) が以下に従って HTML を組み立てる:

- **必須デザイン規約** (style-guide.md 準拠):
  - `<style>` はインライン埋め込み (外部 CSS 禁止)
  - `:root` で CSS 変数を定義し style-guide.md のパレットを使用
  - フォントスタックは system-ui 系 (日本語フォント明示)、外部フォント禁止
  - `<meta name="viewport" content="width=device-width, initial-scale=1">` 必須
  - `@media print` 対応必須
- **必須要素 (種別固有)**: `{style}-style.md` の「必須要素チェックリスト (grep パターン)」をすべて生成 HTML に含める
- **example の参照範囲**: prompt 内で「`reference/examples/{file}.html` の `.problem` / `.fix` カード部分 (相当箇所) を参考に、その他のセクションは無視」のように絞る (コスト削減策 #1)
- **JS 動的タブ禁止**: タブ風 UI が必要なら `<details>` 折りたたみ or `css-tabs.html` の CSS-only radio + label パターンを採用

出力ファイルパスを決定:

- `--output` 指定あり → そのパス
- なし → `<現ディレクトリ>/tmp/<basename>.html` (例: `tmp/plan.md` → `tmp/plan.html`)

出力ディレクトリが存在しなければ作成し、Write tool で HTML を書き込む。

### フェーズ 5: ブラウザ起動

`--no-open` 指定がなければ Bash で以下を実行:

- macOS: `open <output_path>`
- Linux: `xdg-open <output_path>`
- その他 OS: 「browser auto-open unsupported on $sys_platform」と警告して skip

### フェーズ 6: 完了報告

以下のフォーマットでユーザーに報告:

```
## 完了

- 出力: ./tmp/{basename}.html
- style: {style} ({自動判定 | 明示指定})
- ブラウザ: 起動済み (macOS `open`) | 抑制 (--no-open)
- 入力 token 概算: {N} tokens (style-guide + prompt + example + input MD)
- 出力 HTML サイズ: {N} KB
```

token 概算は厳密でなくて良い (style-guide ~500 / prompt ~1,000 / example ~6,000-8,000 / 入力 MD は wc で算出)。

## 注意事項

- 生成 HTML は `tmp/` 配下に出力されコミット対象外 (リポジトリの `.gitignore` で除外済み)
- `--no-open` は CI / SSH 越し操作で必須
- **外部依存ゼロを厳守**: 生成 HTML 内で `https?://` リンクは `<a href>` のみ許容、`<link rel="stylesheet">` / `<script src=>` / Web フォント / Mermaid CDN 等は禁止
- LLM 出力は決定論的でないため、必須要素チェックリストの grep パターン (各 `{style}-style.md` 内) を Step 7 で機械検証する
- 大規模 MD (50KB 超) は警告: 入力 token 上限超過時は部分変換になる可能性があるため、ユーザーに事前通知
