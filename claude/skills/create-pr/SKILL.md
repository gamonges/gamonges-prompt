---
name: create-pr
description: 現在のブランチから既定のベースブランチへ Pull Request を作成する。実装完了後の PR 化、レビュー依頼の準備、`/create-pr` 呼び出しで使用。
disable-model-invocation: true
---

指定されたブランチ（または現在のブランチ）から、リポジトリの既定ブランチ（`gh repo view --json defaultBranchRef -q .defaultBranchRef.name`）向けのプルリクエストを作成します。ユーザーがベースブランチを明示した場合はそれを優先します。

## 補助ドキュメントへの参照

**必ず読む**:

| 補助ドキュメント | 読むタイミング |
|------------------|----------------|
| `./reference/pr-description-template.md` | Phase 5 で PR 本文を生成する時（起動したら必ず通る） |

「念のため全部読む」は禁止。上記以外の補助ファイルを増やす場合は「条件付きで読む」表を別に作り、トリガー条件を書く。

## Notion Page ID によるリファレンス付与

ユーザーがコマンド実行時に Notion のページ ID（例: `DC-6050`, `DC-1234 DC-5678`）を一緒に入力した場合、PR 本文の**先頭**に `ref` 行を自動付与します。

**ルール**（本仕様の SSOT。reference 側では再宣言しない）:

- ユーザーの入力から `DC-` で始まる ID（例: `DC-6050`）をすべて抽出する
- 1 件の場合: `ref DC-6050` を本文の 1 行目に挿入
- 複数件の場合: `ref DC-6050 DC-1234` のようにスペース区切りで 1 行にまとめる
- ID が見つからない場合: ref 行は付与しない（従来通りの動作）
- ref 行の後に空行を 1 行入れてから PR 本文を続ける

```
# ID が見つかった場合の本文構造:
ref DC-6050

## 📝 PR 概要 📝
...

# ID が見つからなかった場合の本文構造:
## 📝 PR 概要 📝
...
```

## Execution Conditions

Phase 0 で「通常 PR」を選択し Phase 1 以降に進む場合にのみ、以下の条件を確認する。Phase 0 自体、および「スタック PR」を選択した場合はこれらの条件を確認しない。

- Current branch is not the repository's default branch
- Current branch has commits that are not in the default branch
- There is no existing Pull Request for the current branch

If any condition is not met:

- Stop the process immediately
- Notify the user which condition failed
- Do not proceed with PR creation

## Execution Process

Phase 0 を実行した上で、通常 PR の場合は Execution Conditions を満たしてから Phase 1 以降を実行する。

### Phase 0: PR 種別選択

「通常 PR として作成しますか、スタック PR として作成しますか？」をユーザーに確認する。

- **通常 PR** を選択した場合: 以降の Phase 1-8 をそのまま実行する（本 Phase 以外の変更はない）
- **スタック PR** を選択した場合: 「新規スタック開始」か「既存スタックへの追加」かをさらに確認し、以下に委譲する。**Phase 1-8 は実行しない**
  - 新規開始 → `Skill` ツールで `stack-pr-init` を呼び出す
  - 既存追加 → `Skill` ツールで `stack-pr-add` を呼び出す
  - いずれの場合も、レイヤー追加の完了後に自動連鎖させず「まとめて PR 化する場合は `/stack-pr-submit` を実行してください」と案内する（複数レイヤーを積んでからまとめて submit したいケースがあるため）

### Phase 1: Verify Branch Status

```bash
# Get current branch
current_branch=$(git branch --show-current)

# ベースブランチを 1 箇所で解決し、以降のフェーズはこの変数だけを使う。
# リポジトリごとに main / develop が異なるため、ブランチ名をハードコードすると
# 存在しないブランチを参照して `fatal: ambiguous argument` になる
base_branch=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
# ユーザーがベースブランチを明示した場合はその値で上書きする

# ローカルの $base_branch 参照は worktree ベースの作業では fetch/pull されずに
# 古いまま固定されがちで、その状態で bare な "${base_branch}..HEAD" を使うと
# 本来 base に取り込み済みのコミットまで大量に「差分」として出てくる（誤検知）。
# 以降の差分計算はすべて origin/$base_branch を使う。
# コロン無し fetch（refspec 無し）なら、$base_branch が別 worktree で
# checkout 中でも "refused to fetch into branch checked out" エラーにならない
git fetch origin "$base_branch"

# Verify branch is not the default branch
if [ "$current_branch" = "$base_branch" ]; then
    echo "Error: Cannot create PR from the default branch ($base_branch)"
    exit 1
fi

# Check if there are commits ahead of the base branch（originの最新を基準にする。
# ローカルの $base_branch 参照では判定しない）
commits_ahead=$(git rev-list --count "origin/${base_branch}..HEAD")
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

# Working tree の透明性確認（PR には含まれないが、gh pr create が警告を出すため事前に説明）
staged_count=$(git status --porcelain | grep -c -E '^[AMD]' || true)
untracked_count=$(git status --porcelain | grep -c -E '^\?\?' || true)
modified_count=$(git status --porcelain | grep -c -E '^ [AMD]' || true)
```

ユーザー向けに以下を表示する（数値が 0 でない場合のみ）:

```
ℹ️ working tree status (PR 本体には含まれません):
- ステージ済み変更: ${staged_count} 件
- 未追跡ファイル: ${untracked_count} 件
- 未ステージ変更: ${modified_count} 件
```

`gh pr create` 実行時の "Warning: N uncommitted changes" がこれらの合計と一致することを事前に説明し、ユーザーの不安を解消する。

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
# Get changed files（$base_branch は Phase 1 で解決・fetch 済み。origin/ を必ず付ける）
changed_files=$(git diff --name-only "origin/${base_branch}...HEAD")

# Get commit messages
commit_messages=$(git log "origin/${base_branch}..HEAD" --pretty=format:"%s")

# Get diff stats
diff_stats=$(git diff "origin/${base_branch}...HEAD" --stat)
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

PR 本文の構成と Notion Page ID の挿入位置は `./reference/pr-description-template.md` を参照する。

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
  --base "$base_branch" \
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
