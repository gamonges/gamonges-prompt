#!/usr/bin/env bash
# SessionStart hook: 直近 1 ヶ月の tmp/lessons.md エントリを additionalContext に注入
# 公式: https://code.claude.com/docs/en/hooks
#
# tmp/lessons.md フォーマット (append-only): 各エントリは `- [YYYY-MM-DD] {要約}` で開始
# NOTE: date -v は BSD/macOS 専用。Linux 環境では date -d '1 month ago' にフォールバック
# NOTE: 機微情報を扱う場合は CLAUDE.md:L28-L46 の env-var indirection を参照
# NOTE: CWD 基準で tmp/lessons.md を探す（プロジェクト root で起動された場合に効く）

set -euo pipefail

LESSONS_FILE="tmp/lessons.md"

# ファイル不存在なら exit 0 (素通し)
[[ -f "$LESSONS_FILE" ]] || exit 0

# 1 ヶ月前の日付を YYYY-MM-DD で取得 (macOS / Linux 互換)
CUTOFF=$(date -v-1m +%Y-%m-%d 2>/dev/null || date -d '1 month ago' +%Y-%m-%d 2>/dev/null || true)

if [[ -z "$CUTOFF" ]]; then
  # date 両系統失敗 → tail -10 でフォールバック inject + stderr 警告で運用者に通知
  echo "[hook-inject-recent-lessons] WARN: date コマンドの 1ヶ月前算出に両系統とも失敗。tail -10 でフォールバック inject します。" >&2
  RECENT=$(grep -E '^- \[' "$LESSONS_FILE" | tail -10)
  [[ -z "$RECENT" ]] && exit 0
  jq -n --arg recent "$RECENT" '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: ("## tmp/lessons.md 末尾 10 件 (date 算出失敗のためフォールバック)\n\n" + $recent)
    }
  }'
  exit 0
fi

# append-only 規約前提だが、防御的に sort してから tail で最新 10 件
# パターン: `- [YYYY-MM-DD]` で開始する行を抽出 (日付フォーマット validation 付き)、日付が CUTOFF 以降のみ
RECENT=$(awk -v cutoff="$CUTOFF" '
  /^- \[[0-9]{4}-[0-9]{2}-[0-9]{2}\]/ {
    date = substr($0, 4, 10)
    if (date >= cutoff) print
  }
' "$LESSONS_FILE" | sort -k1 | tail -10)

# 抽出結果が空: フォーマット異常検知 (lessons.md が空でないのに 0 件抽出)
if [[ -z "$RECENT" ]]; then
  TOTAL=$(wc -l < "$LESSONS_FILE")
  if [[ "$TOTAL" -gt 0 ]]; then
    echo "[hook-inject-recent-lessons] WARN: lessons.md に $TOTAL 行存在するが '- [YYYY-MM-DD]' 形式の CUTOFF=$CUTOFF 以降エントリが 0 件。フォーマット規約違反の可能性あり。" >&2
  fi
  exit 0
fi

# additionalContext として注入
jq -n --arg recent "$RECENT" --arg cutoff "$CUTOFF" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: ("## 直近 1 ヶ月の関連教訓 (" + $cutoff + " 以降, tmp/lessons.md より)\n\n" + $recent)
  }
}'
