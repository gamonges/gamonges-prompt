# research-style: 調査ドキュメント用デザイン指示

## 目的

調査ドキュメントを「**全部見せず、見たい箇所だけ見られる**」構造に HTML 化する。質問数や情報量に応じて、シンプルな縦並び / `<details>` 折りたたみ / CSS-only タブ / サイドバー (2 ペイン) を使い分け、参照リンクを目立つ pill 形式で強調する。

## 期待される構造

### パターン A: 質問数 ≤ 3、情報量少 (シンプル縦並び)

```
<header>
  <h1>{title}</h1>
  <dl class="meta">調査日 / 質問数 / 結論サマリ</dl>
</header>

<section class="qa-card">
  <h2 class="question">質問 1: {要約}</h2>
  <div class="answer">
    <p>調査結果に基づいた回答</p>
  </div>
  <div class="references">
    <h3>参照</h3>
    <a class="reference-pill" href="src/path/file.ts:L42">src/path/file.ts:L42</a>
    <a class="reference-pill" href="https://...">外部ドキュメント</a>
  </div>
</section>
```

### パターン B: 質問数 4-7 (`<details>` 折りたたみ)

各 Q&A を `<details><summary>` で折りたたみ、最初の 1 件のみ `open` 属性で初期展開。

### パターン C: 質問数 ≥ 8 または本文 > 5000 文字 (サイドバー 2 ペイン or CSS-only タブ)

- 画面幅 > 900px: `display: grid; grid-template-columns: 240px 1fr; gap: 24px;` のサイドバー (左に質問リスト、右に本文)
- サイドバーは `position: sticky; top: 20px;` で追従
- 質問数が 3-5 で「並列にざっと見たい」場合は `reference/examples/css-tabs.html` のタブパターンも可

## デザイン指示

- **質問見出し (`.question`)**:
  - `color: var(--accent: #0969da); border-bottom: 2px solid var(--border);`
  - `::before { content: "Q "; color: var(--muted); }`
- **回答カード (`.answer`)**:
  - `background: var(--callout-bg: #ddf4ff); border-left: 4px solid var(--callout-border: #54aeff);`
  - 通常段落より少し余白を多く `padding: 16px 20px;`
- **参照 pill (`.reference-pill`)**:
  - `display: inline-block; padding: 4px 12px; border-radius: 16px;`
  - `background: var(--card-bg); border: 1px solid var(--border); color: var(--accent);`
  - `font-family: monospace; font-size: 0.85em;`
  - hover で `background: var(--callout-bg);`
- **サイドバー (パターン C)**:
  - 左カラム: 質問の番号付きリスト、`<a href="#q1">` でページ内アンカー
  - 右カラム: 各 Q&A セクション、ID 付与 (`<section id="q1">`)
  - スクロール時にサイドバー追従 (`position: sticky; top: 20px;`)
- **判定アルゴリズム**: 入力 MD の `## 質問` 見出し数をカウント
  - ≤ 3 → パターン A
  - 4-7 → パターン B
  - ≥ 8 または本文サイズ > 5KB → パターン C

## 参考にすべき example

- `reference/examples/adr-pipeline.html` の `<details>` パターン (L132-148) — パターン B 用
- サイドバー 2 ペインは標準的な `grid` レイアウトで構築 (specific example なし、CSS Grid の基本)
- タブが必要な場合は `reference/examples/css-tabs.html` (パターン C のサブパターン)

## 必須要素チェックリスト (grep パターン)

```
Q&A 構造:        <h[23][^>]*>.*?(質問|Q\d|Question)  または  class="qa-card"
参照 pill:       class="reference-pill"  (最低 1 個)
回答セクション:   class="answer"  または  <h[34]>回答</h[34]>
```

パターン別の追加要件:

```
パターン B (4-7 件):   <details
パターン C (≥ 8 件):   class="sidebar"  または  display:\s*grid  または  position:\s*sticky
パターン C のタブ版:   <input type="radio" name="tab
```

少なくとも Q&A 構造 / reference-pill / answer の 3 パターンが必須。質問数に応じたパターンの追加要件も検証。
