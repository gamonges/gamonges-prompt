# review-style: PR レビュードキュメント用デザイン指示

## 目的

PR / コード / 計画レビューの指摘事項を「**指摘対象 → 起きている問題 → 修正案**」の流れで人間レビュアが直感的に追えるように HTML 化する。severity (Critical / Minor / Info / Good) を視覚的に区別し、コード snippet と修正案コードを左右または上下で対比して提示する。

## 期待される構造

```
<header>
  <h1>{title}</h1>
  <dl class="meta">対象 PR / レビュー日 / 総合判定 / 件数サマリ</dl>
</header>

<section class="summary">
  <table>severity 集計表 (Critical N 件 / Minor N 件 / Info N 件 / Good N 件)</table>
</section>

<section class="card critical">
  <h2><span class="severity-badge critical">Critical</span> 指摘 1 タイトル</h2>
  <p class="location"><code>src/path/to/file.ts:L42</code></p>
  <div class="problem">
    <h3>問題</h3>
    <pre><code>// 該当コード snippet (引用)</code></pre>
    <p>何が問題か、なぜ修正が必要か</p>
  </div>
  <div class="fix">
    <h3>修正案</h3>
    <pre><code>// 修正後コード</code></pre>
    <p>修正による効果と注意点</p>
  </div>
</section>

<section class="card minor">...</section>
<section class="card info">...</section>
<section class="card good">...</section>
```

## デザイン指示

- **severity 色分け**:
  - Critical: `--p1: #d1242f` (赤)、背景 `#fff5f5`
  - Minor: `--p2: #bf8700` (橙)、背景 `#fffbeb`
  - Info: `--p3: #0969da` (青)、背景 `#eff6ff`
  - Good: `--done: #1a7f37` (緑)、背景 `#f0fff4`
- **severity-badge**: `display: inline-block; padding: 2px 10px; border-radius: 12px; color: #fff; font-size: 0.78em; font-weight: 600;` でピル型
- **コード snippet (`<pre>`)**: 引用元は light コードブロック (`--code-bg`)、修正案は dark コードブロック (`--code-bg-dark` + `--code-fg-dark`) で対比を強調
- **問題と修正案のレイアウト**:
  - 縦並び (デフォルト): `.problem` → `.fix` を上下に配置
  - 横並び (画面幅 > 900px): `display: grid; grid-template-columns: 1fr 1fr; gap: 16px;` で 2 カラム
- **ファイル参照**: `<code>src/path/to/file.ts:L42</code>` 形式、`.location` クラスでカード上部に配置
- **集計表**: 件数 0 のレベルも `0 件` と表示 (全件可視化)、`<span class="severity-badge">` を表内でも使用

## 参考にすべき example

- `reference/examples/fix-plan.html` の `.problem` / `.fix` カードレイアウト (L160-200) を主要な参考に
- ヘッダの `<dl class="meta">` パターンは `reference/examples/adr-pipeline.html` の L215-225 を参考に
- **その他のセクションは無視**してよい (コスト削減のため参照範囲を絞る)

## 必須要素チェックリスト (grep パターン)

`tmp/stability-check.sh` 等で以下を機械検証する:

```
severity badge:    class="severity-badge\s+(critical|minor|info|good)"
集計表:           <table[^>]*>.*?(Critical|Minor|Info|Good).*?</table>  (DOTALL)
コード snippet:    <pre[^>]*>.*?<code  (最低 2 個、引用 + 修正案)
問題セクション:    <div class="problem"  または  <h3>問題</h3>
修正案セクション:  <div class="fix"  または  <h3>修正案</h3>
ファイル参照:      <code[^>]*>[^<]*:L\d+</code>  (最低 1 個)
```

少なくとも上記 6 パターンすべてが grep で検出されること (Critical/Minor/Info/Good いずれかの指摘が 0 件の場合、該当 badge は省略可)。
