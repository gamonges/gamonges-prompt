#!/usr/bin/env bash
# PreToolUse hook: tmp/ コミット、および git add . / -A / --all を block する
# 公式: https://code.claude.com/docs/en/hooks
# matcher: "Bash" 限定で settings.json から登録

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# git add コマンドかどうか確認
if ! echo "$COMMAND" | grep -qE '^[[:space:]]*git[[:space:]]+add([[:space:]]|$)'; then
  exit 0
fi

# git add の引数部分を取り出す (前後にスペースを付けて引数境界を統一)
ARGS=" $(echo "$COMMAND" | sed -E 's/^[[:space:]]*git[[:space:]]+add[[:space:]]*//') "

# 以下のいずれかに該当すれば block:
#   - tmp/ パスを含む
#   - 引数に単独の . (カレント全追加)
#   - 引数に単独の -A (全変更追加)
#   - 引数に単独の --all
block=0
if echo "$ARGS" | grep -qE '\btmp/'; then
  block=1
elif echo "$ARGS" | grep -qE '[[:space:]]\.[[:space:]]'; then
  block=1
elif echo "$ARGS" | grep -qE '[[:space:]]-A[[:space:]]'; then
  block=1
elif echo "$ARGS" | grep -qE '[[:space:]]--all[[:space:]]'; then
  block=1
fi

if [[ $block -eq 1 ]]; then
  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "tmp/ 配下、もしくは 'git add .' / 'git add -A' / 'git add --all' はコミット禁止です。対象ファイルを明示的に指定してください (CLAUDE.md の Git ルール準拠)。"
  }
}
EOF
fi

exit 0
