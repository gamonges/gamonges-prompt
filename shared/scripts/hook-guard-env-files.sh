#!/usr/bin/env bash
# PreToolUse hook: .env 系のファイルの Read・Edit・Write・MultiEdit・apply_patch を deny する
# 公式: https://code.claude.com/docs/en/hooks
# matcher: "Read|Edit|Write|MultiEdit" 限定で settings.json から登録
# （Codex の hooks.json にも同じ定義が入る。Codex では Edit / Write の matcher が apply_patch にも当たる）
#
# permissions の deny は否定を書けず、deny が allow より先に評価されるので、`**/*.env*` では
# .env.example・.env.sample を通せない。例外のある判定を本 hook に移し、例外の無い名前（.env・*.env）は
# permissions にも残す（本 hook が install 漏れで動かないときの二重の守り）。
# 判定は basename を小文字にして行う: .env と一致・.env. で始まる（.env.example・.env.sample を除く）・.env で終わる。
# 出すのは deny だけ（ask を出さないので、Claude Code と Codex で同じ出力になる）。
# Bash 経路（cat .env）は塞がない（AGENTS.md の deny の判断記録の方針）。

set -euo pipefail

DENY_HINT="読む・書く必要があれば、ユーザーに依頼してください（.env.example・.env.sample は通します）。"

# jq が無いと入力を読めない。素通しにするとガードが黙って開くので、固定の deny を出す
if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"jq が無いため .env 系のファイルかを判定できません。'"$DENY_HINT"'"}}'
  exit 0
fi

INPUT=$(cat)
# malformed JSON は silent miss を生むため非ゼロ終了して可観測化
# オブジェクトでない入力（配列・tool_input が false 等）も止める。jq -e . は通し、後続の jq が exit 5 で落ちて素通しする
if ! echo "$INPUT" | jq -e 'type == "object" and ((.tool_input | type) | . == "object" or . == "null")' >/dev/null 2>&1; then
  echo "$(basename "$0"): malformed input JSON" >&2
  exit 2
fi
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')

deny() {  # $1=理由
  jq -n --arg reason "$1 $DENY_HINT" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

is_env_file() {  # $1=パス
  local name
  name=$(basename -- "$1" | LC_ALL=C tr 'A-Z' 'a-z')
  case "$name" in
    .env.example | .env.sample) return 1 ;;
    .env | .env.* | *.env) return 0 ;;
  esac
  return 1
}

# apply_patch（Codex）。入力に file_path が無く、patch 本文は tool_input.command にある。
# 見出し（Add File・Update File・Delete File・Move to）のパスだけを見る。本文は解釈しない。
# 見出しの読み方は hook-lint-skill-frontmatter.sh の patch_touches_tmp_md と同じ（前後を trim する）
if [[ "$TOOL_NAME" == "apply_patch" ]]; then
  patch=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
  headers=0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      '*** Add File: '*) p="${line#'*** Add File: '}" ;;
      '*** Update File: '*) p="${line#'*** Update File: '}" ;;
      '*** Delete File: '*) p="${line#'*** Delete File: '}" ;;
      '*** Move to: '*) p="${line#'*** Move to: '}" ;;
      *) continue ;;
    esac
    headers=$((headers + 1))
    if is_env_file "$p"; then
      deny "apply_patch が .env 系のファイル（${p}）に触れます。"
    fi
  done <<<"$patch"
  # 解釈できない patch（見出しが無い）。.env を含めば止め、含まなければ通す。
  # 全部止めると、文法が将来変わったときに Codex の編集がすべて止まる
  if [[ $headers -eq 0 && "$(printf '%s' "$patch" | LC_ALL=C tr 'A-Z' 'a-z')" == *.env* ]]; then
    deny "apply_patch の見出しを読めず、本文が .env に触れている疑いがあります。"
  fi
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
if [[ -n "$FILE_PATH" ]] && is_env_file "$FILE_PATH"; then
  deny "${TOOL_NAME:-このツール} で .env 系のファイル（${FILE_PATH}）に触れます。"
fi

exit 0
