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

# Codex は permissionDecision: "ask"（確認プロンプト）に未対応で、未対応の値は hook の失敗として
# 扱われ、操作が続行する（= ガードが黙って開く）。Codex の PreToolUse 入力は turn_id を持つ
# （Claude Code の入力には無い）ので、それで見分けて ask を deny に変え、確認をユーザーに戻す。
# 共通ファイルを source しない: source が失敗すると exit コードが 2 以外になり、ガードが黙って開く。
# 同じ関数を ask を返す hook に複製し、verify-skills.sh の対称性 check が存在を確かめる
decide_ask_or_deny() {  # $1=理由
  local decision="ask" reason="$1"
  if echo "$INPUT" | jq -e 'has("turn_id")' >/dev/null 2>&1; then
    decision="deny"
    reason="[要確認] ${reason} — Codex は確認プロンプトに未対応のため止めました。ユーザーに確認し、ユーザー自身に実行してもらってください。"
  fi
  jq -n --arg decision "$decision" --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: $decision,
      permissionDecisionReason: $reason
    }
  }'
}

# パターン照合はすべてここを通す。grep -q / head -1 のように読み手が早期終了すると、
# 書き手（echo）がまだ書いている途中なら SIGPIPE で死んで 141 を返し、set -o pipefail (:L12)
# がパイプライン全体を 141 にする。マッチしているのに if が偽になり、ガードが黙って開く。
# 実測では改行を含む 120 KB の COMMAND で tmp/ の git add が素通しした（パイプバッファは 64 KB）。
#
# 「echo は builtin だから SIGPIPE を受けない」は成立しない。bash はパイプラインの builtin も
# サブシェルとして fork するため、外部コマンドと同じく死ぬ。
# grep -c は入力を読み切るので SIGPIPE が起きず、|| true で「マッチ 0 件 = exit 1」も吸収する
matches() {  # $1=入力, $2=拡張正規表現
  [[ "$(printf '%s\n' "$1" | grep -cE "$2" || true)" -gt 0 ]]
}

# (1) wrapper コマンド かつ git add を含む → ask 昇格 (内部に隠れた git add を人間判断に委ねる)
#     git add を運ばない探索系 wrapper (find | xargs grep 等) は次の段へ素通し
if matches "$COMMAND" '(^|[[:space:]]|;|&&|\|\|)[[:space:]]*(bash[[:space:]]+-c|eval[[:space:]]|xargs[[:space:]])' \
   && matches "$COMMAND" 'git[[:space:]]+add'; then
  decide_ask_or_deny "git add を含む wrapper コマンド (bash -c / eval / xargs) を検出しました。'git add .' / '-A' / 'tmp/' を隠していないか目視確認のうえ承認してください (CLAUDE.md の Git ルール準拠)。"
  exit 0
fi

# (2) 直接 git add コマンドかどうか確認 (コマンド境界考慮: 先頭 or `;` `&&` `||` `|` の後)
if ! matches "$COMMAND" '(^|[;&|]|&&|\|\|)[[:space:]]*git[[:space:]]+add([[:space:]]|$)'; then
  exit 0
fi

# git add の引数部分を取り出す (`&&` / `;` / `|` 境界で打ち切り、前後にスペースを付けて引数境界を統一)
# head -1 を挟まず bash 側で先頭行を取る。head は最初の改行で早期終了するため、マッチが複数あると
# 書き手が SIGPIPE で死に、代入が 141 で失敗して set -e がスクリプトごと落とす（= ガードが開く）
ARGS=$(echo "$COMMAND" | grep -oE '(^|[;&|]|&&|\|\|)[[:space:]]*git[[:space:]]+add[^;&|]*' || true)
ARGS="${ARGS%%$'\n'*}"
ARGS=" $(echo "$ARGS" | sed -E 's/^.*git[[:space:]]+add[[:space:]]*//') "

# 以下のいずれかに該当すれば block:
#   - tmp/ パスを含む (但し pathspec exclusion `:!tmp/` は除外)
#   - 引数に単独の . (カレント全追加)
#   - 引数に単独の -A (全変更追加)
#   - 引数に単独の --all
block=0
if matches "$ARGS" '(^|[[:space:]])tmp/' && ! matches "$ARGS" ':!tmp/'; then
  block=1
elif matches "$ARGS" '[[:space:]]\.[[:space:]]'; then
  block=1
elif matches "$ARGS" '[[:space:]]-A[[:space:]]'; then
  block=1
elif matches "$ARGS" '[[:space:]]--all[[:space:]]'; then
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
