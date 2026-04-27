# unified.md テンプレート（review skill 補助）

Phase 4 で `./tmp/review/unified.md` に書き出す統合レポートのテンプレート。

```markdown
# コードレビューレポート

**PR #{number}**: {title}
**ブランチ**: `{head}` → `{base}`
**レビュー日**: {date}
**変更ファイル数**: {count}ファイル | **差分規模**: {small/medium/large}
**プロジェクトタイプ**: {frontend/backend/unknown}

---

## ❌ CI Failures（最優先）

> Phase 1.6 で `tmp/review/_ci-failures.md` が生成されている場合のみ表示する。CI 失敗が無い場合は本セクション全体を省略する。

| Check | Bucket | Link |
|-------|--------|------|
| {check name} | fail | {link} |

### {check name} の失敗詳細

```
{tail -n 30 of failed log}
```

---

## CI 前提確認

> 以下は CI で自動検出されるため、本レビューではチェック対象外:
> - 型エラー（typecheck）
> - コーディング規約違反（lint）
> - テスト失敗（test）
>
> 本レビューは CI では検出困難な設計・アーキテクチャ・セキュリティ観点に集中する。

---

## 変更サマリ

### 修正の目的

{この PR が解決する課題・要件（1-3文）}

### アプローチ

- {主要な変更1}
- {主要な変更2}
- ...

### 設計・アーキテクチャ判断

{該当しない場合は「特になし」}

### 影響範囲

{変更が影響するモジュール・機能。リグレッションリスクがあれば記載}

---

## 👀 人間レビュー観点（Human Review Points）

> AI だけでは判断しきれない、人間の確認が必要なポイント。
> 該当なしのカテゴリは省略。各項目に判断材料となる具体的コンテキストを記載。

### 設計判断

- **H-1. {タイトル}** — `src/path/to/file.tsx:L42`
  {なぜこのアプローチが選ばれたか。代替案があれば記載}

### 仕様整合性

- **H-2. {タイトル}** — `src/path/to/file.tsx:L100`
  {仕様要件との整合が必要な箇所}

### アーキテクチャ統一性

- **H-3. {タイトル}** — `src/path/to/file.tsx (ComponentName)`
  {既存パターンとの一貫性}

### 命名・責務

- **H-4. {タイトル}** — `src/path/to/file.tsx:L20`
  {命名の適切さ、責務の分離}

### その他

- **H-5. {タイトル}** — `src/path/to/file.tsx:L80`
  {パフォーマンス、セキュリティ、拡張性}

---

## ❌ Critical Issues（修正必須）

### C-1. {問題タイトル}
**エージェント**: {指摘元} | **確信度**: High | **カテゴリ**: {tag}
**ファイル**: `src/full/path/to/file.tsx:L42-50`

{詳細説明}

```tsx
// ❌ 現状
<problematic code>

// ✅ 修正案
<fixed code>
```

---

## ⚠️ Minor Issues（改善提案）

### M-1. {問題タイトル}
**エージェント**: {指摘元} | **確信度**: {level} | **カテゴリ**: {tag}
**ファイル**: `src/full/path/to/file.tsx:L15`

{詳細説明}

---

## ℹ️ Info & Questions（確認事項）

### I-1. {タイトル}
**ファイル**: `src/full/path/to/file.tsx:L100`

{詳細説明}

---

## ✅ Good Points（良い実装）

1. **{タイトル}** — {説明} [{エージェント名}]

---

## 📊 サマリー

| 区分 | 件数 |
|------|------|
| ❌ Critical | X件 |
| ⚠️ Minor | Y件 |
| ℹ️ Info | Z件 |
| ✅ Good | W件 |

### 優先対応（Critical がある場合のみ表示）

1. **C-1** `src/path/file.tsx:L42` — {概要}

---

*レビュー by {参加エージェント名一覧}（並列実行）*
```
