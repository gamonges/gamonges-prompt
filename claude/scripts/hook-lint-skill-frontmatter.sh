#!/usr/bin/env bash
# PreToolUse hook: SKILL.md の frontmatter lint (name / description 必須 + トリガー語推奨)
# 公式: https://code.claude.com/docs/en/hooks
# matcher: "Edit|Write|MultiEdit" 限定で settings.json から登録
#
# 検査仕様は claude/skills/_template/reference/skill-frontmatter-spec.md を参照
# - 必須フィールド欠落 → permissionDecision: "deny" でファイル書き込みを阻止
# - トリガー語不足 → permissionDecision: "ask" で人間判断
# - 検査対象外 (非 SKILL.md / _*/SKILL.md) → exit 0 で素通し
#
# NOTE: 機微情報を扱う場合は CLAUDE.md:L28-L46 の env-var indirection を参照
# NOTE: MultiEdit パースは Python フォールバックで多行/特殊文字を安全に扱う (W-B 対応)

set -euo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')

# 1. 検査対象判定: SKILL.md でなければ素通し
if [[ ! "$FILE_PATH" =~ /SKILL\.md$ ]]; then
  exit 0
fi

# _ プレフィックスディレクトリは除外 (_template, _example 等)
if [[ "$FILE_PATH" =~ /_[^/]+/SKILL\.md$ ]]; then
  exit 0
fi

# 2. 検査対象テキストの構築 (Write / Edit / MultiEdit)
CONTENT=""
case "$TOOL_NAME" in
  Write)
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // ""')
    ;;
  Edit)
    OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // ""')
    NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // ""')
    if [[ ! -f "$FILE_PATH" ]]; then
      # 既存ファイルが無い場合は素通し（Edit は通常存在前提）
      exit 0
    fi
    # Python で安全に文字列置換（特殊文字エスケープを気にしない）
    CONTENT=$(python3 - <<PY
import sys
with open("$FILE_PATH", "r") as f:
    content = f.read()
old = $(echo "$OLD" | jq -Rs .)
new = $(echo "$NEW" | jq -Rs .)
print(content.replace(old, new, 1), end="")
PY
)
    ;;
  MultiEdit)
    if [[ ! -f "$FILE_PATH" ]]; then
      exit 0
    fi
    EDITS_JSON=$(echo "$INPUT" | jq -c '.tool_input.edits // []')
    CONTENT=$(python3 - <<PY
import json
with open("$FILE_PATH", "r") as f:
    content = f.read()
edits = json.loads('''$EDITS_JSON''')
for e in edits:
    old = e.get("old_string", "")
    new = e.get("new_string", "")
    content = content.replace(old, new, 1)
print(content, end="")
PY
)
    ;;
  *)
    exit 0
    ;;
esac

if [[ -z "$CONTENT" ]]; then
  exit 0
fi

# 3. frontmatter ブロックを抽出 (--- で囲まれた YAML)
FRONTMATTER=$(echo "$CONTENT" | awk '
  /^---$/ { c++; if (c==1) { in_fm=1; next } else if (c==2) { exit } }
  in_fm { print }
')

if [[ -z "$FRONTMATTER" ]]; then
  # frontmatter が無い SKILL.md は不正だが、新規作成途中の可能性もある → ask
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: "SKILL.md に YAML frontmatter (--- で囲まれたブロック) が見つかりません。新規作成途中であれば続行してください。詳細は claude/skills/_template/reference/skill-frontmatter-spec.md を参照。"
    }
  }'
  exit 0
fi

# 4. 必須フィールドの存在チェック
HAS_NAME=$(echo "$FRONTMATTER" | grep -cE '^name:' || true)
HAS_DESC=$(echo "$FRONTMATTER" | grep -cE '^description:' || true)

if [[ "$HAS_NAME" -eq 0 ]] || [[ "$HAS_DESC" -eq 0 ]]; then
  MISSING=""
  [[ "$HAS_NAME" -eq 0 ]] && MISSING="${MISSING}name "
  [[ "$HAS_DESC" -eq 0 ]] && MISSING="${MISSING}description "
  MISSING=$(echo "$MISSING" | sed 's/ $//')

  jq -n --arg missing "$MISSING" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("SKILL.md frontmatter に必須フィールド (" + $missing + ") が欠落しています。詳細は claude/skills/_template/reference/skill-frontmatter-spec.md を参照。")
    }
  }'
  exit 0
fi

# 5. description 値の抽出 (多行 YAML 対応: description: | や > も含めて次の key 行直前まで)
DESC_VALUE=$(echo "$FRONTMATTER" | awk '
  /^description:/ { in_desc=1 }
  in_desc && /^[a-zA-Z_-]+:/ && !/^description:/ { exit }
  in_desc { print }
')

# 6. トリガー語の存在チェック (連語化、単一文字を回避、case-insensitive)
TRIGGER_REGEX='時に|する時|使用|呼び出|キーワード|トリガー|when |trigger|use this|use when'

if ! echo "$DESC_VALUE" | grep -qiE "$TRIGGER_REGEX"; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: "SKILL.md description にトリガー語 (時に / する時 / 使用 / 呼び出 / キーワード / トリガー / when / trigger / use this / use when) が含まれていません。Claude の skill 自動選択精度に影響します。承認して保存しますか?"
    }
  }'
  exit 0
fi

# すべての検査をパス → exit 0 (素通し)
exit 0
