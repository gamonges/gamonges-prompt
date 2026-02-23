---
description: Create a Pull Request to develop branch from current branch (/create-pr)
---

指定されたブランチ（または現在のブランチ）から develop ブランチ向けのプルリクエストを作成します。

**IMPORTANT**: Always respond in Japanese

## Notion Page ID によるリファレンス付与

ユーザーがコマンド実行時にNotionのページID（例: `DC-6050`, `DC-1234 DC-5678`）を一緒に入力した場合、PR本文の**先頭**に `ref` 行を自動付与します。

**ルール**:

- ユーザーの入力から `DC-` で始まるID（例: `DC-6050`）をすべて抽出する
- 1件の場合: `ref DC-6050` を本文の1行目に挿入
- 複数件の場合: `ref DC-6050 DC-1234` のようにスペース区切りで1行にまとめる
- IDが見つからない場合: ref 行は付与しない（従来通りの動作）
- ref 行の後に空行を1行入れてからPR本文を続ける

## Execution Conditions

You must verify the following conditions before proceeding:

- Current branch is not `develop` or `main`
- Current branch has commits that are not in `develop`
- There is no existing Pull Request for the current branch

If any condition is not met:

- Stop the process immediately
- Notify the user which condition failed
- Do not proceed with PR creation

## Execution Process

When all conditions are met, execute these phases in order:

### Phase 1: Verify Branch Status

```bash
# Get current branch
current_branch=$(git branch --show-current)

# Verify branch is not develop or main
if [ "$current_branch" = "develop" ] || [ "$current_branch" = "main" ]; then
    echo "Error: Cannot create PR from develop or main branch"
    exit 1
fi

# Check if there are commits ahead of develop
commits_ahead=$(git rev-list --count develop..HEAD)
if [ "$commits_ahead" -eq 0 ]; then
    echo "Error: No commits to create PR"
    exit 1
fi

# Check if PR already exists for current branch
existing_pr=$(gh pr list --head "$current_branch" --state all --json number --jq '.[0].number')
if [ -n "$existing_pr" ] && [ "$existing_pr" != "null" ]; then
    echo "Error: PR already exists (#$existing_pr)"
    exit 1
fi
```

### Phase 2: Generate PR Title

ブランチ名から PR のタイトルを生成します。

ブランチ命名規則の例:

- `feature/add-user-authentication` → "Add user authentication"
- `fix/login-bug` → "Fix login bug"
- `refactor/user-service` → "Refactor user service"

タイトル生成ルール:

- プレフィックス（feature/, fix/, refactor/など）を除去
- ハイフンやアンダースコアをスペースに変換
- 先頭を大文字化
- 簡潔で分かりやすいタイトルにする

### Phase 3: Analyze Changes

変更内容を分析して PR 本文を生成するための情報を収集します。

```bash
# Get changed files
changed_files=$(git diff --name-only develop...HEAD)

# Get commit messages
commit_messages=$(git log develop..HEAD --pretty=format:"%s")

# Get diff stats
diff_stats=$(git diff develop...HEAD --stat)
```

### Phase 4: Determine PR Purpose

変更内容とコミットメッセージから、PR の目的を判断します：

- **機能追加**: 新しい機能やエンドポイントの追加
- **仕様変更**: 既存機能の動作変更
- **バグ修正**: バグや不具合の修正
- **リファクタリング**: コードの構造改善（機能変更なし）

複数該当する場合は、主要な目的を選択します。

### Phase 5: Generate PR Description

`.github/PULL_REQUEST_TEMPLATE.md`のフォーマットに従って PR 本文を生成します。

**Notion Page ID の処理**:

ユーザー入力から `DC-` で始まるIDを抽出し、見つかった場合はPR本文の先頭に挿入します。

```
# IDが見つかった場合の本文構造:
ref DC-6050

## 📝 PR 概要 📝
...

# IDが見つからなかった場合の本文構造:
## 📝 PR 概要 📝
...
```

テンプレート構成:

```markdown
## 📝 PR 概要 📝

- **目的**:
  - [機能追加/仕様変更/バグ修正/リファクタリング]
- **関連リンク**:
  - [関連する Issue、Notion、Figma など]
- **変更点の概要**:
  - [主要な変更内容を箇条書き]

## 👮‍♂️ 動作確認 👮‍♂️

- [ ] API に破壊的な変更がない（エンドポイント削除やレスポンス変更など）
- [ ] ローカルで動作確認済み
- [ ] CI が正常に通過
- [ ] ドキュメント（README, Swagger など）が更新済み
- [ ] gemini のレビュー指摘をチェック
```

変更内容に基づいて、以下を自動的に埋めます：

- 目的（複数該当する場合はすべてチェック）
- 変更点の概要（コミットメッセージと変更ファイルから生成）
- Notion Page IDが指定されていた場合、関連リンクにも記載する

関連リンクは手動で追加する必要があることをユーザーに通知します。

### Phase 6: Create Pull Request

```bash
# Create PR with generated title and description
gh pr create \
  --title "$pr_title" \
  --body "$pr_description" \
  --base develop \
  --head "$current_branch" \
  --draft
```

ドラフト PR として作成し、ユーザーが内容を確認してから公開できるようにします。

### Phase 7: Open PR in Browser

```bash
# Open the created PR in browser
gh pr view --web
```

### Phase 8: Completion Report

ユーザーに以下の情報を報告します：

- 作成された PR の番号と URL
- PR のタイトル
- 生成された PR 本文の主要な内容
- 次のステップ:
  - 関連リンクを追加する
  - 動作確認チェックリストを確認する
  - ドラフトを解除して公開する
  - レビュアーをアサインする

例:

```
✅ プルリクエストを作成しました

PR #123: Add user authentication
URL: https://github.com/organization/repo/pull/123

📝 次のステップ:
1. PRの「関連リンク」セクションに関連するIssueやドキュメントを追加してください
2. 動作確認チェックリストを確認してください
3. 準備ができたら、ドラフトを解除して公開してください
4. レビュアーをアサインしてください
```
