#!/usr/bin/env bash
# PreToolUse hook: 型 aware lint (oxlint/tsgolint/eslint 等) のフルプロジェクト実行を block する
# 公式: https://code.claude.com/docs/en/hooks
# matcher: "Bash" 限定で settings.json から登録
#
# 背景: dresscode-backend/dresscode-frontend では oxlint が型 aware (tsgolint バックエンド) で
#   動作しており、`pnpm run lint` 等のフル実行はローカル PC のリソースをほぼ食い尽くす。
#   一方でプロジェクトごとに用意された「変更ファイルのみ」向けスクリプト名 (lint:changed 等) は
#   プロジェクト固有なので、個別に知らなくても済むよう deny-by-default で判定する:
#   「対象範囲を限定している痕跡が無ければフル実行とみなして block」。
#
# 対象範囲限定の痕跡とみなすもの (いずれか1つでもあれば通す):
#   - サブコマンド名に changed / diff / staged を含む (例: lint:changed, lint:staged)
#   - 具体的なファイル拡張子・glob (.ts/.tsx/.js/.jsx/.mjs/.cjs や *.ts 等) を含む
#   - Turbo/pnpm workspace の差分フィルタ (--filter, --since) を含む
#   - git diff / git status 経由で動的にファイルリストを組み立てている

set -euo pipefail

INPUT=$(cat)
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then
  echo "$(basename "$0"): malformed input JSON" >&2
  exit 2
fi
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# (1) lint 系コマンドかどうか判定
#   - pnpm/npm/yarn (run) lint[:subcommand]
#   - oxlint / eslint / tsgolint を直接 (npx 経由も含む) 実行
is_lint_cmd=0
if echo "$COMMAND" | grep -qE '(^|[;&|]|&&|\|\|)[[:space:]]*(pnpm|npm|yarn)([[:space:]]+run)?[[:space:]]+lint([:][[:alnum:]_-]+)?([[:space:]]|$)'; then
  is_lint_cmd=1
elif echo "$COMMAND" | grep -qE '(^|[;&|]|&&|\|\|)[[:space:]]*(npx[[:space:]]+)?(oxlint|eslint|tsgolint)([[:space:]]|$)'; then
  is_lint_cmd=1
fi

if [[ $is_lint_cmd -eq 0 ]]; then
  exit 0
fi

# (2) 対象範囲限定の痕跡を探す。1つでもあれば素通し。
scoped=0
if echo "$COMMAND" | grep -qE ':[[:space:]]*[[:alnum:]_-]*(changed|diff|staged)'; then
  scoped=1
elif echo "$COMMAND" | grep -qE '\.(ts|tsx|js|jsx|mjs|cjs)([[:space:]]|$|['\''""])' ; then
  scoped=1
elif echo "$COMMAND" | grep -qE '(--filter|--since)([[:space:]=]|$)'; then
  scoped=1
elif echo "$COMMAND" | grep -qE 'git[[:space:]]+(diff|status)'; then
  scoped=1
fi

if [[ $scoped -eq 1 ]]; then
  exit 0
fi

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "対象ファイルを限定していない lint コマンドを検出しました。型 aware lint (oxlint/tsgolint/eslint 等) のフルプロジェクト実行はローカル PC のリソースを大量消費します。変更ファイルのみを対象にしたコマンド (プロジェクト固有の lint:changed 等、または明示的なファイルパス/拡張子指定) を使ってください。CI 相当のフルチェックが本当に必要な場合はユーザーに確認してください。"
  }
}
EOF

if [[ -n "${CLAUDE_CODE_HOOK_TRACE:-}" ]]; then
  mkdir -p ~/.claude/logs
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $(basename "$0") matched=true decision=deny" >> ~/.claude/logs/hook-trace.log
fi

exit 0
