#!/usr/bin/env bash
# PreToolUse hook: tmp/ コミット、および git add . / -A / --all を block する
# 公式: https://code.claude.com/docs/en/hooks
# matcher: "Bash" 限定で settings.json から登録
#
# scope 限定: 静的に判定可能な範囲のみ扱う。
#   - 直接の `git add ...` (含む `cd foo && git add ...`) は deny
#   - wrapper (`bash -c "..."` / `eval "..."` / `xargs ...`) で git add を運ぶものは内部展開不可なので ask 昇格
#   - git add を運ばない探索系 wrapper (`find | xargs grep` 等) は通す (コード探索を止めないため)
#   - `eval` 内の動的展開 (例: `eval "$VAR"`) は対象外 (静的解析の限界)

set -euo pipefail

INPUT=$(cat)
# malformed JSON は silent miss を生むため非ゼロ終了して可観測化
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then
  echo "$(basename "$0"): malformed input JSON" >&2
  exit 2
fi
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# (1) wrapper コマンド かつ git add を含む → ask 昇格 (内部に隠れた git add を人間判断に委ねる)
#     git add を運ばない探索系 wrapper (find | xargs grep 等) は次の段へ素通し
if echo "$COMMAND" | grep -qE '(^|[[:space:]]|;|&&|\|\|)[[:space:]]*(bash[[:space:]]+-c|eval[[:space:]]|xargs[[:space:]])' \
   && echo "$COMMAND" | grep -qE 'git[[:space:]]+add'; then
  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": "git add を含む wrapper コマンド (bash -c / eval / xargs) を検出しました。'git add .' / '-A' / 'tmp/' を隠していないか目視確認のうえ承認してください (CLAUDE.md の Git ルール準拠)。"
  }
}
EOF
  exit 0
fi

# (2) 直接 git add コマンドかどうか確認 (コマンド境界考慮: 先頭 or `;` `&&` `||` `|` の後)
if ! echo "$COMMAND" | grep -qE '(^|[;&|]|&&|\|\|)[[:space:]]*git[[:space:]]+add([[:space:]]|$)'; then
  exit 0
fi

# git add の引数部分を取り出す (`&&` / `;` / `|` 境界で打ち切り、前後にスペースを付けて引数境界を統一)
ARGS=$(echo "$COMMAND" | grep -oE '(^|[;&|]|&&|\|\|)[[:space:]]*git[[:space:]]+add[^;&|]*' | head -1)
ARGS=" $(echo "$ARGS" | sed -E 's/^.*git[[:space:]]+add[[:space:]]*//') "

# 以下のいずれかに該当すれば block:
#   - tmp/ パスを含む (但し pathspec exclusion `:!tmp/` は除外)
#   - 引数に単独の . (カレント全追加)
#   - 引数に単独の -A (全変更追加)
#   - 引数に単独の --all
block=0
if echo "$ARGS" | grep -qE '(^|[[:space:]])tmp/' && ! echo "$ARGS" | grep -qE ':!tmp/'; then
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
  # opt-in trace: CLAUDE_CODE_HOOK_TRACE 環境変数が定義されている時のみログ出力
  if [[ -n "${CLAUDE_CODE_HOOK_TRACE:-}" ]]; then
    mkdir -p ~/.claude/logs
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $(basename "$0") matched=true decision=deny" >> ~/.claude/logs/hook-trace.log
  fi
fi

exit 0
