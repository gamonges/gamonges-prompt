#!/usr/bin/env bash
# retrospective skill 同梱 script: 指定日に作成・マージされた PR を JSON で出力する
# 引数: $1 = 対象日付 (YYYY-MM-DD), 省略時は当日
# NOTE: macOS / Linux 共通動作（gh + date のみ依存）

set -euo pipefail

# 依存ツール確認
for cmd in gh jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  fi
done

# gh 認証確認
if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh CLI が未認証です。'gh auth login' を実行してください。" >&2
  exit 1
fi

# 対象日付の取得（引数 or 当日）
TARGET_DATE="${1:-$(date +%Y-%m-%d)}"

# 日付形式検証 (YYYY-MM-DD)
if [[ ! "$TARGET_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "ERROR: 日付形式が不正です: '$TARGET_DATE'。YYYY-MM-DD で指定してください。" >&2
  exit 1
fi

# gh search で PR を検索
# author:@me で認証ユーザーが作成した PR
# created:$TARGET_DATE で対象日に作成された PR
QUERY="author:@me created:$TARGET_DATE"

# stderr 退避でエラー詳細を保持 (認証失効/レート制限/jq 構文エラー等を伝搬)
gh_err=$(mktemp)
if ! result=$(gh api -X GET "search/issues" \
  -f q="$QUERY type:pr" \
  --jq '{
    total_count: .total_count,
    items: [.items[] | {
      number,
      title,
      state,
      created_at,
      updated_at,
      repo: (.repository_url | split("/") | .[-2:] | join("/")),
      html_url,
      labels: [.labels[].name]
    }]
  }' 2>"$gh_err"); then
    echo "ERROR: gh API 呼出に失敗しました" >&2
    echo "  詳細: $(cat "$gh_err")" >&2
    rm -f "$gh_err"
    exit 1
fi
rm -f "$gh_err"

# 結果を整形して出力
echo "$result" | jq --arg date "$TARGET_DATE" '. + {target_date: $date}'
