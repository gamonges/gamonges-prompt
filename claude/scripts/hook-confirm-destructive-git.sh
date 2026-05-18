#!/usr/bin/env bash
# PreToolUse hook: 破壊的 git 操作 (--force / --hard 等) を ask 昇格する
# 公式: https://code.claude.com/docs/en/hooks
# matcher: "Bash" 限定で settings.json から登録
# 既存 permissions.ask は prefix match (git push:*, git reset:*) で広範。
# 本 hook は破壊フラグの場合のみ ask を確定するための補完。

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# 破壊的 git 操作の検出パターン:
#   - git push --force / -f / --force-with-lease
#   - git reset --hard
#   - git worktree remove --force
#   - git clean -f
#   - git checkout --force
#   - git branch -D
match=0
if echo "$COMMAND" | grep -qE 'git[[:space:]]+push[[:space:]].*(-f([[:space:]]|$)|--force([[:space:]]|$)|--force-with-lease)'; then
  match=1
elif echo "$COMMAND" | grep -qE 'git[[:space:]]+reset[[:space:]].*--hard'; then
  match=1
elif echo "$COMMAND" | grep -qE 'git[[:space:]]+worktree[[:space:]]+remove[[:space:]].*--force'; then
  match=1
elif echo "$COMMAND" | grep -qE 'git[[:space:]]+clean[[:space:]].*-f'; then
  match=1
elif echo "$COMMAND" | grep -qE 'git[[:space:]]+checkout[[:space:]].*--force'; then
  match=1
elif echo "$COMMAND" | grep -qE 'git[[:space:]]+branch[[:space:]].*-D([[:space:]]|$)'; then
  match=1
fi

if [[ $match -eq 1 ]]; then
  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": "破壊的 git 操作を検出しました。事前にユーザー確認が必要です (CLAUDE.md の「破壊的コマンド事前確認」準拠)。"
  }
}
EOF
fi

exit 0
