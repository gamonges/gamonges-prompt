#!/usr/bin/env bash
# PreToolUse hook: .env 系のファイルの Read・Edit・Write・MultiEdit・Grep・NotebookEdit・apply_patch を deny する
# 公式: https://code.claude.com/docs/en/hooks
# matcher: "Read|Edit|Write|MultiEdit|Grep|NotebookEdit" 限定で settings.json から登録
# （Codex の hooks.json にも同じ定義が入る。Codex では Edit / Write の matcher が apply_patch にも当たる）
#
# permissions の deny は否定を書けず、deny が allow より先に評価されるので、`**/*.env*` では
# .env.example・.env.sample を通せない。例外のある判定を本 hook に移し、例外の無い名前（.env・*.env）は
# permissions にも残す（本 hook が install 漏れで動かないときの二重の守り）。
# 判定は basename を小文字にして行う: .env と一致・.env. .env- .env_ で始まる・.env で終わる・<名前>.env.<拡張子>
# （拡張子がコードのものを除く）。例外は区切りが . - _ の example・sample と <名前>.env.example・<名前>.env.sample。
# 出すのは deny だけ（ask を出さないので、Claude Code と Codex で同じ出力になる）。
# Bash 経路（cat .env）は塞がない（AGENTS.md の deny の判断記録の方針）。

set -euo pipefail

DENY_HINT="読む・書く必要があれば、ユーザーに依頼してください（.env.example・.env.sample などの見本と、x.env.ts のようなコードは通します）。"

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
INPUT_CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

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

# .env の前に名前がある形（x.env.ts）で通すコードの拡張子。秘密の写し（.bak・.json・.local）は既定で止め、
# 例外を名指しで通す（未知の接尾辞を列挙の漏れで通さない）
CODE_EXTS="ts|tsx|mts|cts|js|jsx|mjs|cjs|py|rb|go|rs|java|kt|php|swift|dart|vue|svelte"

is_env_name() {  # $1=basename
  local name
  name=$(printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z')
  case "$name" in
    .env) return 0 ;;
    .env[._-]example | .env[._-]sample | *.env.example | *.env.sample) return 1 ;;
    # basename が .env で始まる形は、拡張子によらず止める
    .env.* | .env-* | .env_* | *.env) return 0 ;;
    *.env.*)
      [[ "${name##*.}" =~ ^($CODE_EXTS)$ ]] && return 1
      return 0
      ;;
  esac
  return 1
}

is_env_file() {  # $1=パス。相対パスの基点は INPUT_CWD（入力の cwd）
  local p="$1" target
  is_env_name "$(basename -- "$p")" && return 0
  # symlink は解決した先の名前でも判定する。相対パスは入力の cwd を基点にする（hook のプロセスの cwd は
  # 入力の cwd と同じとは限らない。Codex の apply_patch の見出しのパスは相対）
  [[ "$p" == /* || -z "$INPUT_CWD" ]] || p="$INPUT_CWD/$p"
  [[ -L "$p" ]] || return 1
  # 壊れた symlink は realpath が失敗するので、リンク先の文字列の名前で判定する
  target=$(realpath -- "$p" 2>/dev/null) || target=$(readlink -- "$p" 2>/dev/null) || return 1
  is_env_name "$(basename -- "$target")"
}

is_env_glob() {  # $1=Grep の glob
  local g last
  g=$(printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z')
  [[ "$g" == *.env* ]] || return 1
  last="${g##*/}"
  # 通すのは、.env の前に 1 文字以上（* を含む）ある形で、.env.<コードの拡張子>（波括弧なら全部がコードの拡張子）で終わるもの
  [[ "$last" =~ ^.+\.env\.(($CODE_EXTS)|\{(($CODE_EXTS),)*($CODE_EXTS)\})$ ]] && return 1
  return 0
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

# file_path（Read・Edit・Write・MultiEdit）・path（Grep）・notebook_path（NotebookEdit）
for key in file_path path notebook_path; do
  FILE_PATH=$(echo "$INPUT" | jq -r --arg k "$key" '.tool_input[$k] // "" | strings')
  if [[ -n "$FILE_PATH" ]] && is_env_file "$FILE_PATH"; then
    deny "${TOOL_NAME:-このツール} で .env 系のファイル（${FILE_PATH}）に触れます。"
  fi
done
# Grep はディレクトリを対象にできる。名前で覆えるのは、path がファイルのときと glob が .env を指すときだけ
GLOB=$(echo "$INPUT" | jq -r '.tool_input.glob // "" | strings')
if [[ -n "$GLOB" ]] && is_env_glob "$GLOB"; then
  deny "${TOOL_NAME:-このツール} の glob（${GLOB}）が .env 系のファイルを指します。"
fi

exit 0
