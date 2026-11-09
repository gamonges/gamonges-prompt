#!/usr/bin/env bash
# UserPromptSubmit hook: ユーザーの訂正表現を検知し、auto-memory への記録を促す
# （旧 tmp/lessons.md 方式は SessionStart の無条件前渡しを伴うため廃止）
# 公式: https://code.claude.com/docs/en/hooks
# 出力: hookSpecificOutput.additionalContext で訂正の可能性を Claude に通知
#
# NOTE: 機微情報を扱う場合は CLAUDE.md:L28-L46 の env-var indirection を参照
# NOTE: matcher なし (UserPromptSubmit は matcher 非対応)

set -euo pipefail

INPUT=$(cat)
# malformed JSON は silent miss を生むため非ゼロ終了して可観測化
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then
  echo "$(basename "$0"): malformed input JSON" >&2
  exit 2
fi
PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""')

if [[ -z "$PROMPT" ]]; then
  exit 0
fi

# 通知（task-notification）と他セッションのメッセージ（agent-message）はユーザーの発言ではないので、
# 閉じたブロックだけを照合から外す。先頭一致にしないのは、ブロックと訂正が混ざった入力で訂正を見落とさないため。
# 除去に失敗したら元の文字列で照合する（誤発火は余計な指示が 1 回出るだけで、訂正の見落としより軽い）。
# bash の ${var//…/} は長い入力で数分かかるので使わない
MATCH_TEXT=$(printf '%s' "$PROMPT" | perl -0777 -pe 's/<task-notification>.*?<\/task-notification>//gs; s/<agent-message\b[^>]*>.*?<\/agent-message>//gs' 2>/dev/null) || MATCH_TEXT="$PROMPT"

# 訂正パターン (連語化して誤発火を抑制):
# - 違うので / そうじゃない / やり直し / 違うので直し
# - なぜ.*した(のですか? / ですか? / 末尾の ?) — 疑問形シーケンスを連語で要求 (文字クラス誤用を解消)
# - 間違って(る/いる/います/い) + 訂正系語尾 (誤発火防止)
# - stop doing / wrong approach / no, that / no, you / no, the
TRIGGER_REGEX='違うので|そうじゃない|やり直|違うので直|なぜ.*した(のですか[？\?]|ですか[？\?]|[？\?]$)|間違(っ|い)てる|間違(っ|い)ています|間違いです|間違って(いる|い|る)よ|間違いだよ|stop doing|wrong approach|no, that|no, you|no, the'

# hook-block-tmp-commit.sh の matches() の複製。echo | grep -q は、grep が最初のマッチで終わると書き手が
# SIGPIPE で死に、pipefail で照合が偽になる（約 64KB を超える入力で、前半の訂正を見落とした）。
# grep -c は入力を読み切るので SIGPIPE が起きない
matches() {  # $1=入力, $2=拡張正規表現
  [[ "$(printf '%s\n' "$1" | grep -cE "$2" || true)" -gt 0 ]]
}

if matches "$MATCH_TEXT" "$TRIGGER_REGEX"; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "🔁 [自己改善ループ] 訂正の可能性を検知。応答の最後に、再現条件と回避ルールを auto-memory へ `type: feedback` として保存すること（既存の記憶に該当があれば新規作成せず更新する）。教訓が無ければ '記録なし' と明示。"
  }
}
EOF
  # opt-in trace: CLAUDE_CODE_HOOK_TRACE 環境変数が定義されている時のみログ出力
  if [[ -n "${CLAUDE_CODE_HOOK_TRACE:-}" ]]; then
    mkdir -p ~/.claude/logs
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $(basename "$0") matched=true" >> ~/.claude/logs/hook-trace.log
  fi
fi

exit 0
