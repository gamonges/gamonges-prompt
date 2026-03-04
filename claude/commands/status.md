---
description: ワークフローの現在地・進捗を一覧表示する（/status）
---

ワークフローの現在地・進捗を一覧表示する。ファイル生成なし、コンソール出力のみ。

**重要**: ソースコード変更禁止。ファイル生成禁止。コンソール出力のみ。
**IMPORTANT**: Always respond in Japanese.

## ワークフロー上の位置付け

独立して使用可能。任意のタイミングで実行できる。

## 実行条件

なし（常に実行可能）。

## 実行プロセス

### フェーズ 1: ファイル状態の確認

以下のファイルの存在と最終更新日時を確認する:

- [ ] `./tmp/context.md`
- [ ] `./tmp/research.md`
- [ ] `./tmp/feedback.md`
- [ ] `./tmp/plan.md`
- [ ] `./tmp/plan-review.md`
- [ ] `./tmp/spec-check.md`
- [ ] `./tmp/review/unified.md`
- [ ] `./tmp/fix-plan.md`
- [ ] `./tmp/fixes.md`

### フェーズ 2: 実装進捗の確認

`./tmp/plan.md` が存在する場合:

- [ ] ステップ一覧を抽出する
- [ ] 各ステップのチェックボックス状態（`- [ ]` / `- [x]`）を確認する
- [ ] 進捗率を算出する

### フェーズ 3: 仕様状態の確認

- [ ] `openspec/specs/` が存在する場合、配下の spec.md ファイル数をカウントする
- [ ] `openspec/changes/` が存在する場合、アクティブな変更提案を一覧表示する
  - 各変更提案のアーティファクト（proposal.md, specs/, design.md, tasks.md）の有無を確認する
- [ ] `openspec/config.yaml` が存在するかを確認する

### フェーズ 4: Git 状態の確認

- [ ] 現在のブランチ名を確認する
- [ ] PR が存在するかを確認する（`gh pr list --head` で確認）
- [ ] 未コミットの変更があるかを確認する

### フェーズ 5: 出力

以下のフォーマットでコンソールに出力する:

```markdown
# ワークフロー状態

## ファイル状態
| ファイル | 状態 | 最終更新 |
|---------|------|---------|
| tmp/context.md | 存在 / なし | YYYY-MM-DD HH:MM |
| tmp/research.md | 存在 / なし | YYYY-MM-DD HH:MM |
| tmp/feedback.md | 存在 / なし | YYYY-MM-DD HH:MM |
| tmp/plan.md | 存在 / なし | YYYY-MM-DD HH:MM |
| tmp/plan-review.md | 存在 / なし | YYYY-MM-DD HH:MM |
| tmp/spec-check.md | 存在 / なし | YYYY-MM-DD HH:MM |
| tmp/review/unified.md | 存在 / なし | YYYY-MM-DD HH:MM |
| tmp/fix-plan.md | 存在 / なし | YYYY-MM-DD HH:MM |

## 実装進捗（plan.md）
- [x] ステップ 1: ...
- [ ] ステップ 2: ...
進捗: 1/N (XX%)

## 仕様状態（openspec/）
- config.yaml: 存在 / なし
- specs/: N 個の仕様ファイル
- changes/: M 個のアクティブな変更提案
  - {change-name-1}: proposal + specs + design + tasks
  - {change-name-2}: proposal + specs

## Git 状態
- ブランチ: {branch-name}
- PR: #{number} ({state}) / なし
- 未コミット変更: あり / なし

## 推奨アクション
→ [次に実行すべきコマンドとその理由]
```

### 推奨アクションの決定ロジック

以下の優先順位で推奨アクションを決定する:

1. `tmp/plan.md` なし → `/design` で計画を作成
2. `tmp/plan.md` あり、`tmp/spec-check.md` なし → `/spec-check` で整合性を検証
3. `tmp/plan-review.md` なし → `/review-plan` で計画をレビュー
4. 実装進捗 < 100% → `/implement` で実装を続行
5. 実装進捗 100%、`tmp/review/unified.md` なし → `/review` でレビュー
6. `tmp/review/unified.md` あり、`tmp/fix-plan.md` なし → `/fix` で修正計画を作成
7. `tmp/fix-plan.md` あり → `/implement ./tmp/fix-plan.md` で修正を実行
8. 実装完了、レビュー完了 → `/spec-propose` or `/spec-archive` で仕様を永続化、その後 `/create-pr`
