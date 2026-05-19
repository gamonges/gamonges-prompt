#!/usr/bin/env bash
# worktree-cleanup skill 同梱 script: マージ済 PR とそれに対応する worktree を列挙する
# 公式: 親 SKILL.md からこの script を実行
# NOTE: macOS / Linux 共通動作（gh + git のみ依存）。jq が必要

set -euo pipefail

# 依存ツール確認
for cmd in gh git jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  fi
done

# gh 認証確認
if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh CLI が未認証です。'gh auth login' を実行してください。" >&2
  exit 1
fi

# マージ済 PR の head branch を取得（最新 50 件）
# stderr 退避でエラー詳細を保持 (silent 化を防ぐ)
gh_err=$(mktemp)
if ! merged_json=$(gh pr list --state merged --limit 50 --json number,headRefName 2>"$gh_err"); then
  echo "ERROR: gh pr list 失敗: $(cat "$gh_err")" >&2
  rm -f "$gh_err"
  exit 1
fi
rm -f "$gh_err"
merged_branches=$(echo "$merged_json" | jq -r '.[] | "\(.number)\t\(.headRefName)"')

if [[ -z "$merged_branches" ]]; then
  echo "マージ済 PR は見つかりませんでした"
  exit 0
fi

# worktree 一覧を取得（path と branch のペア）
# awk のデフォルト FS では path にスペースが含まれると truncate されるため、substr で行頭から取得
worktrees=$(git worktree list --porcelain 2>/dev/null \
  | awk '/^worktree / { path = substr($0, 10) } /^branch / { gsub("refs/heads/","",$2); print path"\t"$2 }')

if [[ -z "$worktrees" ]]; then
  echo "worktree は登録されていません"
  exit 0
fi

# マージ済 branch と worktree を突合
echo "# マージ済 PR と対応 worktree 一覧"
echo ""
echo "| PR | branch | worktree path |"
echo "|----|--------|----------------|"

match_count=0
while IFS=$'\t' read -r pr_number branch_name; do
  while IFS=$'\t' read -r worktree_path worktree_branch; do
    if [[ "$branch_name" == "$worktree_branch" ]]; then
      echo "| #$pr_number | $branch_name | $worktree_path |"
      match_count=$((match_count + 1))
    fi
  done <<< "$worktrees"
done <<< "$merged_branches"

echo ""
if [[ $match_count -eq 0 ]]; then
  echo "削除候補の worktree は見つかりませんでした"
else
  echo "削除候補: $match_count 件"
  echo ""
  echo "削除コマンド例:"
  echo '  git worktree remove <worktree path>'
fi
