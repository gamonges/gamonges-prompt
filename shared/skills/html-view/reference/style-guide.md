# html-view 共通デザイン規約

`reference/prompts/{type}-style.md` および `reference/examples/*.html` 共通の **CSS 変数 / フォント / レイアウト規約** を定義する SSOT。Claude が `/html-view` で HTML を組み立てる時、本ファイルの規約に必ず従うこと。

## カラーパレット (CSS 変数)

すべての生成 HTML は `:root` で以下を定義する。GitHub Primer 風配色:

| 変数 | 値 | 用途 |
|------|------|------|
| `--bg` | `#f6f8fa` | ページ背景 (やや暖かいグレー) |
| `--card-bg` | `#ffffff` | カード背景 |
| `--border` | `#d0d7de` | カード枠線 / 区切り |
| `--text` | `#1f2328` | 本文 |
| `--muted` | `#656d76` | 補助テキスト (timestamp / caption / meta) |
| `--code-bg` | `#f0f3f6` | インラインコード / `<pre>` 背景 (light) |
| `--code-bg-dark` | `#1f2328` | ダーク `<pre>` 背景 |
| `--code-fg-dark` | `#e6edf3` | ダーク `<pre>` 文字色 |
| `--link` | `#0969da` | リンク (アクセント青) |
| `--accent` | `#0969da` | 強調アクセント (= --link) |
| `--problem-bg` | `#fff5f5` | 「問題」カード薄背景 |
| `--problem-border` | `#ff8888` | 「問題」カード縦ボーダー |
| `--problem-text` | `#a40e26` | 「問題」見出し文字色 |
| `--fix-bg` | `#f0fff4` | 「修正」カード薄背景 |
| `--fix-border` | `#4ac26b` | 「修正」カード縦ボーダー |
| `--fix-text` | `#1a7f37` | 「修正」見出し文字色 |
| `--p1` | `#d1242f` | 優先度 P1 / Critical (赤) |
| `--p2` | `#bf8700` | 優先度 P2 / Minor (黄) |
| `--p3` | `#0969da` | 優先度 P3 / Info (青) |
| `--p4` | `#6e7781` | 優先度 P4 (グレー) |
| `--done` | `#1a7f37` | 完了マーカー (緑) |
| `--pending` | `#9a6700` | 未完了マーカー (橙) |
| `--rejected` | `#6e7781` | 却下マーカー (グレー) |
| `--highlight` | `#fff8c5` | 重要箇所ハイライト (薄黄) |
| `--callout-bg` | `#ddf4ff` | info callout 背景 (薄青) |
| `--callout-border` | `#54aeff` | info callout 縦ボーダー |

## フォントスタック

```css
font-family:
  -apple-system, BlinkMacSystemFont, "Segoe UI",
  "Hiragino Kaku Gothic ProN", "Hiragino Sans",
  "Yu Gothic UI", "Yu Gothic", "Meiryo",
  "Noto Sans CJK JP", sans-serif;
```

コード用:

```css
font-family:
  "SF Mono", "SFMono-Regular", "Monaco", "Menlo",
  "Consolas", "Liberation Mono", monospace;
```

Web フォント (Google Fonts 等) の読み込みは禁止。

## レイアウト規約

- `body`: `max-width: 1100px; margin: 0 auto; padding: 24px;`
- 標準フォントサイズ: 15px、行間 1.6
- 見出し行間: 1.3
- カード: `padding: 16px 20px; border-radius: 8px; margin: 16px 0; border: 1px solid var(--border);`
- 縦ボーダー強調: `border-left: 4px solid <color>;`
- コードブロック: `padding: 12px 16px; border-radius: 6px; overflow-x: auto;`

## レスポンシブ

```css
@media (max-width: 700px) {
  body { padding: 16px 12px; }
  table { font-size: 14px; }
  .card, .step { padding: 12px 14px; }
}
```

## 印刷対応 (`@media print` 必須)

```css
@media print {
  body { background: white; max-width: none; }
  details { break-inside: avoid; }
  details:not([open]) > *:not(summary) { display: none; }
  details[open] > *:not(summary) { display: block; }
  pre { white-space: pre-wrap; }
  a { color: var(--text); text-decoration: none; }
  .no-print { display: none; }
}
```

## 単体完結原則 (外部依存ゼロ)

生成 HTML は以下を厳守する:

- ❌ 外部 CSS (`<link rel="stylesheet" href="https://...">`) の読み込み禁止
- ❌ Web フォント (Google Fonts / Adobe Fonts 等) の読み込み禁止
- ❌ 外部 JavaScript (`<script src="https://...">`) の読み込み禁止
- ❌ Mermaid / KaTeX 等の動的レンダリングライブラリの埋め込み禁止 (CDN 経由になるため)
- ✅ `<a href="https://...">` のリンク先 URL は許容 (クリック時のみアクセスされる)
- ✅ `<style>` はインライン埋め込み、`<script>` を書く場合もインラインのみ

検証コマンド: `grep -E "https?://" tmp/{name}.html | grep -v '<a href'` で 0 件であること。

## アクセシビリティ

- `<html lang="ja">` を必須 (日本語コンテンツ)
- 見出しレベルは飛ばさない (h1 → h2 → h3 の順、h1 → h3 はダメ)
- `<a>` には意味のあるテキスト (「こちら」だけはダメ)
- カラーパレットはコントラスト比 4.5:1 以上 (WCAG 2.1 AA 準拠)
