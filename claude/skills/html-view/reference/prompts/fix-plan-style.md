# fix-plan-style: 修正計画ドキュメント用デザイン指示

## 目的

修正計画を「**現状の問題 ↔ 修正方針**」の対比レイアウトで直感的に把握できるように HTML 化する。複数ラウンドの修正計画 (Round 1 done / Round 2 pending) はタイムライン構造で進捗を可視化、各ステップは problem カードと fix カードを左右または上下に並べて対比を強調する。

## 期待される構造

```
<header>
  <h1>{title}</h1>
  <dl class="meta">対象 PR / Round 番号 / 件数サマリ / 優先度内訳</dl>
</header>

<section class="summary">
  <table class="summary">修正項目集計 (P1 N 件 / P2 N 件 / P3 N 件 / P4 N 件)</table>
</section>

<section class="timeline">
  <h2>Round タイムライン</h2>
  <div class="timeline-card done">
    <h3>Round 1 <span class="status-badge">DONE</span></h3>
    <ul>完了済み修正項目</ul>
  </div>
  <div class="timeline-card pending">
    <h3>Round 2 <span class="status-badge">PENDING</span></h3>
    <ul>今回の修正項目</ul>
  </div>
</section>

<section class="step">
  <header class="step-header">
    <h3>ステップ 1: {修正タイトル}</h3>
    <div class="step-meta">
      <span class="priority p1">P1</span>
      <span>対象: <code>src/path/file.ts:L42</code></span>
    </div>
  </header>
  <div class="step-body">
    <div class="problem">
      <h4>現状の問題</h4>
      <pre><code>// 該当コード</code></pre>
      <p>何が起きているか、影響範囲、再現手順</p>
    </div>
    <div class="fix">
      <h4>修正方針</h4>
      <pre><code>// 修正後コード</code></pre>
      <p>修正による解決メカニズム、副作用</p>
    </div>
  </div>
  <div class="meta-row">
    <strong>関連 PR:</strong> #123 |
    <strong>関連 ADR:</strong> ADR-089 |
    <strong>テスト方針:</strong> ...
  </div>
</section>

<section class="rejected-card">
  <h4>却下された修正案</h4>
  <p>なぜ採用しなかったか</p>
</section>
```

## デザイン指示

- **problem カード**:
  - 背景 `--problem-bg: #fff5f5`、左ボーダー `4px solid #ff8888`
  - 見出し色 `--problem-text: #a40e26`、`h4::before { content: "⚠ "; }`
- **fix カード**:
  - 背景 `--fix-bg: #f0fff4`、左ボーダー `4px solid #4ac26b`
  - 見出し色 `--fix-text: #1a7f37`、`h4::before { content: "✓ "; }`
- **対比レイアウト**:
  - デフォルト: 縦並び (`.problem` → `.fix`)
  - 画面幅 > 900px: `.step-body { display: grid; grid-template-columns: 1fr 1fr; gap: 0; }` で 2 カラム
  - print 時は縦並びに戻す
- **優先度 badge (`.priority`)**:
  - P1 (Critical): `background: var(--p1); color: #fff; padding: 2px 10px; border-radius: 12px;`
  - P2 (High): `background: var(--p2);`
  - P3 (Medium): `background: var(--p3);`
  - P4 (Low): `background: var(--p4);`
- **timeline-card**:
  - `done`: 左ボーダー `--done: #1a7f37` (緑)、status-badge も緑
  - `pending`: 左ボーダー `--pending: #9a6700` (橙)、status-badge も橙
  - 複数ラウンドを `display: flex; gap: 16px;` で横並び (mobile では縦)
- **rejected-card**: `border-left: 4px solid var(--rejected: #6e7781);`、見出し `h4::before { content: "✗ "; }`

## 参考にすべき example

- `reference/examples/fix-plan.html` を **ほぼそのまま参考**に (L100-280 がコアレイアウト)
- 特に `.timeline` / `.timeline-card` パターン (L62-94)、`.problem` / `.fix` カード (L163-185)、`.priority.p1-p4` badge (L119-131) を流用
- ヘッダの `<dl class="meta">` パターンは `reference/examples/adr-pipeline.html` L215-225 を参考に (簡略形でよい)

## 必須要素チェックリスト (grep パターン)

```
problem カード:   class="(card )?problem"
fix カード:       class="(card )?fix"  または  class="step-body".*?class="fix"  (DOTALL)
優先度 badge:    class="priority\s+p[1-4]"
timeline:        class="(timeline|timeline-card)"  (Round が plan に含まれる場合のみ必須)
集計表:           <table[^>]*class="[^"]*summary"  または  <table[^>]*>.*?(P1|P2|P3|P4)
ステップ:        class="step"  (修正項目数と概ね一致)
ファイル参照:     <code[^>]*>[^<]*:L\d+</code>  (最低 1 個)
```

少なくとも problem / fix / priority / step の 4 パターンは必ず検出されること。timeline は Round 表記が plan に含まれる時のみ。
