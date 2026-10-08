# plan-style: 実装計画ドキュメント用デザイン指示

## 目的

実装計画を「**全体アーキテクチャ → レイヤー別実装 → 細かいステップ**」の階層で見やすく HTML 化する。スコープが大きい場合はレイヤー (frontend / backend / infra など) をタブまたは折りたたみで分割し、ユーザーが「見たいレイヤーだけ展開」できる構造にする。ステップカードは番号と進捗状態を視覚的に明示する。

## 期待される構造

```
<header>
  <h1>{title}</h1>
  <dl class="meta">
    <dt>作成日</dt><dd>...</dd>
    <dt>ステップ数</dt><dd>N 個</dd>
    <dt>確信度</dt><dd>high / medium / low の件数</dd>
  </dl>
</header>

<section class="overview">
  <h2>概要 / TL;DR</h2>
  <div class="callout">...</div>
</section>

<section class="file-changes">
  <h2>ファイル変更マップ</h2>
  <pre>
.
├── src/
│   └── newfile.ts                    [NEW]
└── ...
  </pre>
</section>

<!-- レイヤーが 3 つ以上に分かれる場合: CSS-only タブ -->
<!-- レイヤーが 2 つまで or レイヤー区別不要: <details> 折りたたみ -->

<section class="steps">
  <h2>実装ステップ</h2>
  <section class="step-card">
    <header class="step-header">
      <h3>ステップ 1: {title}</h3>
      <span class="step-status pending">pending</span>
    </header>
    <div class="step-body">
      <ul>
        <li>変更対象: <code>path/to/file</code></li>
        <li>テスト方針: ...</li>
      </ul>
    </div>
  </section>
  ...
</section>

<section class="acceptance">
  <h2>受入条件</h2>
  <ul class="checklist">
    <li><input type="checkbox" disabled> AC-1: ...</li>
    ...
  </ul>
</section>
```

## デザイン指示

- **ヘッダ `<dl class="meta">`**: `dt::after { content: ": "; }`、`dd::after { content: " / "; margin-right: 4px; }`、`dd:last-child::after { content: ""; }`
- **ファイル変更マップ**: `<pre>` の中で ASCII tree を保持 (整形しない)、`[NEW]` `[MOD]` `[DEL]` `[KEEP]` を `<span class="tag tag-new">` 等で色付けしてもよい
- **レイヤー分割の判断基準**:
  - レイヤーが **3 つ以上** (例: frontend / backend / infra + DB) → `reference/examples/css-tabs.html` の CSS-only radio タブパターンを採用
  - レイヤーが **2 つまで** または明示的な分割不要 → `<details><summary>...</summary>...</details>` 折りたたみ
  - JS 動的タブは禁止 (再現性が低い)
- **ステップカード**:
  - `border: 1px solid var(--border); border-left: 4px solid var(--accent); border-radius: 8px;`
  - ヘッダ部に gradient: `background: linear-gradient(to right, var(--bg), var(--card-bg));`
  - step-status badge: `pending` (橙)、`in-progress` (青)、`completed` (緑)、`blocked` (赤)
- **受入条件**: `<input type="checkbox" disabled>` で進捗チェック可、`checked` 属性で完了状態を表現
- **確信度 high/medium/low** が plan.md に含まれる場合: 表またはバッジで色分け (high=緑 / medium=黄 / low=赤)

## 参考にすべき example

- `reference/examples/adr-pipeline.html` のヘッダ `<dl class="meta">` (L215-225) と `<details>` 折りたたみパターンを主要な参考に
- ステップカードのレイアウトは `reference/examples/fix-plan.html` の `.step` / `.step-header` / `.step-body` (L133-196) を参考に
- レイヤー分割が必要な場合は `reference/examples/css-tabs.html` の radio + label パターンをそのまま採用

## 必須要素チェックリスト (grep パターン)

```
タイトル:         <h1>
メタ情報:         <dl[^>]*class="[^"]*meta"  または  <header
ファイル変更マップ: <pre[^>]*>.*?\[(NEW|MOD|DEL|KEEP)\].*?</pre>  (DOTALL、最低 1 個)
ステップカード:    class="(step|step-card)"  (plan.md のステップ数と概ね一致)
受入条件:         (受入条件|Acceptance Criteria|AC-\d)
チェックボックス:  <input type="checkbox"  (受入条件用、最低 1 個)
```

レイヤー分割が必要な場合の追加要件 (任意):

```
タブ実装 (3+ レイヤー時): <input type="radio" name="tab
折りたたみ (2 まで時):     <details
```

少なくとも上記 6 パターン (必須分) が grep で検出されること。
