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
# malformed JSON は silent miss を生むため非ゼロ終了して可観測化
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then
  echo "$(basename "$0"): malformed input JSON" >&2
  exit 2
fi
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
    # quote 付き heredoc + 環境変数渡しで bash 変数展開を抑止 (injection 経路を遮断)
    # 失敗時は permissionDecision: ask で明示的にユーザーへ通知（silent abort を防ぐ）
    if ! CONTENT=$(FILE_PATH="$FILE_PATH" OLD="$OLD" NEW="$NEW" python3 - <<'PY' 2>/tmp/skill-lint-err
import os, sys
try:
    with open(os.environ["FILE_PATH"], encoding="utf-8", errors="replace") as f:
        content = f.read()
    content = content.replace(os.environ["OLD"], os.environ["NEW"], 1)
    sys.stdout.write(content)
except Exception as e:
    sys.stderr.write(f"lint-prep-failed: {e}\n")
    sys.exit(2)
PY
    ); then
      jq -n --arg err "$(cat /tmp/skill-lint-err 2>/dev/null)" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "ask",
          permissionDecisionReason: ("SKILL.md lint の前処理に失敗しました: " + $err + " — 内容を目視確認して承認してください。")
        }
      }'
      exit 0
    fi
    ;;
  MultiEdit)
    if [[ ! -f "$FILE_PATH" ]]; then
      exit 0
    fi
    EDITS_JSON=$(echo "$INPUT" | jq -c '.tool_input.edits // []')
    # quote 付き heredoc + 環境変数渡しで bash 変数展開を抑止
    if ! CONTENT=$(FILE_PATH="$FILE_PATH" EDITS_JSON="$EDITS_JSON" python3 - <<'PY' 2>/tmp/skill-lint-err
import json, os, sys
try:
    with open(os.environ["FILE_PATH"], encoding="utf-8", errors="replace") as f:
        content = f.read()
    edits = json.loads(os.environ["EDITS_JSON"])
    for e in edits:
        content = content.replace(e.get("old_string", ""), e.get("new_string", ""), 1)
    sys.stdout.write(content)
except Exception as e:
    sys.stderr.write(f"lint-prep-failed: {e}\n")
    sys.exit(2)
PY
    ); then
      jq -n --arg err "$(cat /tmp/skill-lint-err 2>/dev/null)" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "ask",
          permissionDecisionReason: ("SKILL.md lint の前処理に失敗しました: " + $err + " — 内容を目視確認して承認してください。")
        }
      }'
      exit 0
    fi
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
  # opt-in trace: CLAUDE_CODE_HOOK_TRACE 環境変数が定義されている時のみログ出力
  if [[ -n "${CLAUDE_CODE_HOOK_TRACE:-}" ]]; then
    mkdir -p ~/.claude/logs
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $(basename "$0") matched=true decision=ask reason=trigger-missing" >> ~/.claude/logs/hook-trace.log
  fi
  exit 0
fi

# すべての検査をパス → exit 0 (素通し)
exit 0
