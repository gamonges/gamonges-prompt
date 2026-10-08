#!/usr/bin/env bash
# PreToolUse hook: 破壊的 git 操作 (--force / --hard 等) を ask 昇格する
# 公式: https://code.claude.com/docs/en/hooks
# matcher: "Bash" 限定で settings.json から登録
# 既存 permissions.ask は prefix match (git push:*, git reset:*) で広範。
# 本 hook は破壊フラグの場合のみ ask を確定するための補完。

set -euo pipefail

INPUT=$(cat)
# malformed JSON は silent miss を生むため非ゼロ終了して可観測化
# オブジェクトでない入力（配列・tool_input が false 等）も止める。jq -e . は通し、後続の jq が exit 5 で落ちて素通しする
if ! echo "$INPUT" | jq -e 'type == "object" and ((.tool_input | type) | . == "object" or . == "null")' >/dev/null 2>&1; then
  echo "$(basename "$0"): malformed input JSON" >&2
  exit 2
fi
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Codex は permissionDecision: "ask"（確認プロンプト）に未対応で、未対応の値は hook の失敗として
# 扱われ、操作が続行する（= ガードが黙って開く）。Codex の PreToolUse 入力は turn_id を持つ
# （Claude Code の入力には無い）ので、それで見分けて ask を deny に変え、確認をユーザーに戻す。
# 共通ファイルを source しない: source が失敗すると exit コードが 2 以外になり、ガードが黙って開く。
# 同じ関数を ask を返す hook に複製し、verify-skills.sh の対称性 check が存在を確かめる
decide_ask_or_deny() {  # $1=理由, $2=Codex で止めたときの次の行動（省略可）
  local decision="ask" reason="$1"
  if echo "$INPUT" | jq -e 'has("turn_id")' >/dev/null 2>&1; then
    decision="deny"
    reason="[要確認] ${reason} — Codex は確認プロンプトに未対応のため止めました。${2:-ユーザーに確認し、ユーザー自身に実行してもらってください。}"
  fi
  # trace に実際の判定を記録するため（Codex では deny）
  LAST_DECISION="$decision"
  jq -n --arg decision "$decision" --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: $decision,
      permissionDecisionReason: $reason
    }
  }'
}

if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# パターン照合はすべてここを通す（hook-block-tmp-commit.sh の matches() の複製）。echo | grep -q は、grep が
# 最初のマッチで終わると書き手が SIGPIPE で死に、pipefail で照合が偽になる（改行を含む約 64 KB 超のコマンドで
# 破壊的 git を素通しした）。grep -c は入力を読み切るので SIGPIPE が起きない
matches() {  # $1=入力, $2=拡張正規表現
  [[ "$(printf '%s\n' "$1" | grep -cE "$2" || true)" -gt 0 ]]
}

# contract-link と同じ定義。git -C <path> reset のように git とサブコマンドの間にグローバルオプションが入る形を拾うため
PATH_ARG='("[^"]*"|'"'"'[^'"'"']*'"'"'|(\\.|[^[:space:]\\])+)'
GIT_GLOBAL_OPT="(-[Cc][[:space:]]+$PATH_ARG|--[^[:space:]]+)"
GIT="git[[:space:]]+(${GIT_GLOBAL_OPT}[[:space:]]+)*"

# 破壊的 git 操作の検出パターン:
#   - git push --force / -f / --force-with-lease
#   - git reset --hard
#   - git worktree remove --force
#   - git clean -f
#   - git checkout --force
#   - git branch -D
match=0
if matches "$COMMAND" "${GIT}"'push[[:space:]].*(-f([[:space:]]|$)|--force([[:space:]]|$)|--force-with-lease)'; then
  match=1
elif matches "$COMMAND" "${GIT}"'reset[[:space:]].*--hard'; then
  match=1
elif matches "$COMMAND" "${GIT}"'worktree[[:space:]]+remove[[:space:]].*--force'; then
  match=1
elif matches "$COMMAND" "${GIT}"'clean[[:space:]].*(-f([dqxX]+)?([[:space:]]|$)|--force)'; then
  match=1
elif matches "$COMMAND" "${GIT}"'checkout[[:space:]].*(-f([[:space:]]|$)|--force)'; then
  match=1
elif matches "$COMMAND" "${GIT}"'branch[[:space:]].*-D([[:space:]]|$)'; then
  match=1
fi

if [[ $match -eq 1 ]]; then
  decide_ask_or_deny "破壊的 git 操作を検出しました。事前にユーザー確認が必要です (CLAUDE.md の「破壊的コマンド事前確認」準拠)。"
  # opt-in trace: CLAUDE_CODE_HOOK_TRACE 環境変数が定義されている時のみログ出力
  if [[ -n "${CLAUDE_CODE_HOOK_TRACE:-}" ]]; then
    mkdir -p ~/.claude/logs
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $(basename "$0") matched=true decision=${LAST_DECISION:-ask}" >> ~/.claude/logs/hook-trace.log
  fi
fi

exit 0
