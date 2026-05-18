#!/usr/bin/env bash
# PostToolUse hook: タスクの区切り (gh pr create / openspec archive 等) を検知し
# 自己改善ループの振り返り（tmp/lessons.md 末尾追記）を促す
# 公式: https://code.claude.com/docs/en/hooks
#
# 対象 tool: Bash 系（matcher 無しで全 tool 受信し、script 内で tool_input.command 判定）
# 既存 /retrospective skill (日次粒度) と異なり、本 hook は **タスク単位** の振り返りを促す
#
# NOTE: 機微情報を扱う場合は CLAUDE.md:L28-L46 の env-var indirection を参照

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# トリガーパターン配列 (将来の追加を容易に)
# 公式 gh CLI の挙動: gh pr create / gh pr create --draft / gh pr create --fill / heredoc body 等の全てが
# 先頭 "gh pr create" でマッチする
TRIGGER_PATTERNS=(
  '^[[:space:]]*gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'
  '^[[:space:]]*mv[[:space:]].*tmp/plan\.md[[:space:]]+openspec'
  '^[[:space:]]*git[[:space:]]+mv[[:space:]].*tmp/plan\.md[[:space:]]+openspec'
  '^[[:space:]]*cp[[:space:]].*openspec/changes/.*specs/'
  '^[[:space:]]*mv[[:space:]].*openspec/changes/.*archive/'
)

matched=""
for pattern in "${TRIGGER_PATTERNS[@]}"; do
  if echo "$COMMAND" | grep -qE "$pattern"; then
    # マッチしたパターンを context に含めるため抽出
    matched=$(echo "$COMMAND" | grep -oE "$pattern" | head -1)
    break
  fi
done

if [[ -z "$matched" ]]; then
  exit 0
fi

# JSON エスケープ用に matched を安全化（jq に渡して context を構築）
jq -n --arg trigger "$matched" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("📝 [自己改善ループ] タスクの区切りを検知 (\($trigger))。次の応答前に:\n1. 本タスクの失敗 / 学び を 1-3 件抽出\n2. 既存 tmp/lessons.md と重複しないか確認\n3. 重複なければ末尾追記 (append-only)\n4. 教訓が無ければ '記録なし' と明示")
  }
}'

exit 0
