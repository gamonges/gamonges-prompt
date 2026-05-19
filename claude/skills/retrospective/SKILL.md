---
name: retrospective
description: 指定日の Pull Request 群を振り返り学びを抽出する。日次レビュー、週次サマリ、振り返り目的で `/retrospective [date]` 呼び出しで使用。
---

指定された日（または今日）に作成したプルリクエストを振り返り、学びと知見をまとめる。

**規約**: CLAUDE.md の Skills 共通規約に従う

## 補助ドキュメントへの参照

| 補助ドキュメント | 読むタイミング |
|------------------|----------------|
| `./reference/data-fetching.md` | Phase 1 で PR を取得する時 / API レート制限を確認する時 |
| `./reference/output-format.md` | Phase 4 でレポートを出力する時 / Phase 2-3 の分析観点を確認する時 |
| `./scripts/daily-prs.sh` | Phase 1 で日次 PR 集計を最小実装で取得する時 |

「念のため全部読む」は禁止。表のトリガー条件に該当する場合のみ読み込む。

## 引数

- `date` (オプション): 振り返る日付（YYYY-MM-DD 形式）。省略時は今日の日付を使用
- 例: `/retrospective 2026-05-18`

## 実行プロセス

### Phase 1: プルリクエストの収集

1. GitHub ユーザー情報を取得（`mcp_github_get_me`）
2. PR を取得（**`./reference/data-fetching.md` を参照**）:
   - 優先度 1: GitHub Search API（1 リクエストで完了）
   - 優先度 2: 個別リポジトリへフォールバック（5 リポジトリ並列）
3. PR が 0 件なら早期リターン
4. 必要な PR のみ詳細情報を収集（タイトル / 変更ファイル数 / レビューコメント / マージ状態）

最小実装が必要な場合は `./scripts/daily-prs.sh $YYYY-MM-DD` で日次 PR 集計を取得できる。

### Phase 2: 実装内容の分析

各 PR を技術的側面 / コード品質 / 連携の 3 観点で分析する。詳細観点は `./reference/output-format.md` を参照。

### Phase 3: 学びと知見の抽出

実装の傾向 / 得られた学び / 改善の余地 を整理する。詳細観点は `./reference/output-format.md` を参照。

### Phase 4: 振り返りレポートの生成

`./reference/output-format.md` のテンプレートに従って Markdown レポートを出力する。

### Phase 5: 完了報告

- 対象日 / 取得 PR 数 / 主要な学びを 3-5 行で要約
- 出力レポートのパス（または直接出力）を提示
