#!/usr/bin/env bash
# UserPromptSubmit hook: ユーザーの訂正表現を検知し、tmp/lessons.md への記録を促す
# 公式: https://code.claude.com/docs/en/hooks
# 出力: hookSpecificOutput.additionalContext で訂正の可能性を Claude に通知
#
# NOTE: 機微情報を扱う場合は CLAUDE.md:L28-L46 の env-var indirection を参照
# NOTE: matcher なし (UserPromptSubmit は matcher 非対応)

set -euo pipefail

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""')

if [[ -z "$PROMPT" ]]; then
  exit 0
fi

# 訂正パターン (連語化して誤発火を抑制):
# - 違うので / そうじゃない / やり直し / 違うので直し
# - なぜ.*した[のですか？\?] (疑問形限定)
# - 間違い / 間違っ
# - stop doing / wrong approach / no, that / no, you / no, the
TRIGGER_REGEX='違うので|そうじゃない|やり直|違うので直|なぜ.*した[のですか？\?]|間違い|間違っ|stop doing|wrong approach|no, that|no, you|no, the'

if echo "$PROMPT" | grep -qE "$TRIGGER_REGEX"; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "🔁 [自己改善ループ] 訂正の可能性を検知。応答の最後に、訂正パターンを tmp/lessons.md に末尾追記すること（再現条件 + 回避ルール）。教訓が無ければ '記録なし' と明示。"
  }
}
EOF
fi

exit 0
