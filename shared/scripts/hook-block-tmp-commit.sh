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
# オブジェクトでない入力（配列・tool_input が false 等）も止める。jq -e . は通し、後続の jq が exit 5 で落ちて素通しする
if ! echo "$INPUT" | jq -e 'type == "object" and ((.tool_input | type) | . == "object" or . == "null")' >/dev/null 2>&1; then
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

# contract-link と同じ定義。git -C <path> add のように git とサブコマンドの間にグローバルオプションが入る形を拾うため
PATH_ARG='("[^"]*"|'"'"'[^'"'"']*'"'"'|(\\.|[^[:space:]\\])+)'
GIT_GLOBAL_OPT="(-[Cc][[:space:]]+$PATH_ARG|--[^[:space:]]+)"
GIT_ADD="git[[:space:]]+(${GIT_GLOBAL_OPT}[[:space:]]+)*add"
# -c は他のオプション文字と束ねられる（-lc・-ce）ので、c の前後の文字を許す
SHELL_C="([^[:space:]]*/)?(ba|z|k|da)?sh[[:space:]]+(-[^[:space:]]+[[:space:]]+)*-[A-Za-z]*c[A-Za-z]*([[:space:]]|\$)"

# 直接の git add の deny を先に判定する。wrapper の ask を先にすると、wrapper の外の直接の git add まで
# ask に弱まるため
# (1) 直接 git add コマンド (コマンド境界考慮: 先頭 or `;` `&&` `||` `|` の後)。git add の出現ごとの引数を
#     1 行ずつ取り出し（`&&` / `;` / `|` 境界で打ち切り、前後にスペースを付けて引数境界を統一）、まとめて判定する。
#     出現ごとにループすると 1 件あたり数プロセスを起動し、多数の句で hook の timeout に掛かる（= 素通し）
block=0
if matches "$COMMAND" "(^|[;&|]|&&|\\|\\|)[[:space:]]*${GIT_ADD}([[:space:]]|\$)"; then
  ARGS=$(echo "$COMMAND" | grep -oE "(^|[;&|]|&&|\\|\\|)[[:space:]]*${GIT_ADD}[^;&|]*" || true)
  ARGS=$(printf '%s\n' "$ARGS" | sed -E "s/^.*${GIT_ADD}[[:space:]]*/ /; s/\$/ /")
  # 以下のいずれかに該当すれば block:
  #   - tmp/ パスを含む (但し pathspec exclusion `:!tmp/` を含む git add は除外。除外は git add の出現ごと)
  #   - 引数に単独の . / -A / --all (全変更追加)
  tmp_hits=$(printf '%s\n' "$ARGS" | grep -E '(^|[[:space:]])tmp/' | grep -cvF ':!tmp/' || true)
  if [[ "${tmp_hits:-0}" -gt 0 ]] || matches "$ARGS" '[[:space:]](\.|-A|--all)[[:space:]]'; then
    block=1
  fi
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
  exit 0
fi

# (2) wrapper コマンド かつ git add を含む → ask 昇格 (内部に隠れた git add を人間判断に委ねる)
#     git add を運ばない探索系 wrapper (find | xargs grep 等) は素通し。外側の境界があるので ssh -c は拾わない
if matches "$COMMAND" "(^|[[:space:]]|;|&&|\\|\\|)[[:space:]]*(${SHELL_C}|eval[[:space:]]|xargs[[:space:]])" \
   && matches "$COMMAND" "$GIT_ADD"; then
  decide_ask_or_deny "git add を含む wrapper コマンド (bash -c / eval / xargs) を検出しました。'git add .' / '-A' / 'tmp/' を隠していないか目視確認のうえ承認してください (CLAUDE.md の Git ルール準拠)。"
  exit 0
fi

exit 0
