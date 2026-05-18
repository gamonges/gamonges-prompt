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
CUTOFF=$(date -v-1m +%Y-%m-%d 2>/dev/null || date -d '1 month ago' +%Y-%m-%d 2>/dev/null || echo "")

if [[ -z "$CUTOFF" ]]; then
  # date コマンドが両方失敗 → exit 0 (素通し)
  exit 0
fi

# append-only 規約前提だが、防御的に sort してから tail で最新 10 件
# パターン: `- [YYYY-MM-DD]` で開始する行を抽出、日付が CUTOFF 以降のみ
RECENT=$(awk -v cutoff="$CUTOFF" '
  /^- \[/ {
    date = substr($0, 4, 10)
    if (date >= cutoff) print
  }
' "$LESSONS_FILE" | sort -k1 | tail -10)

# 抽出結果が空なら exit 0 (素通し)
[[ -z "$RECENT" ]] && exit 0

# additionalContext として注入
jq -n --arg recent "$RECENT" --arg cutoff "$CUTOFF" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: ("## 直近 1 ヶ月の関連教訓 (" + $cutoff + " 以降, tmp/lessons.md より)\n\n" + $recent)
  }
}'
