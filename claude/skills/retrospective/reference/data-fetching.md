# PR データ取得の詳細手順

> SKILL.md フェーズ 1 で「PR を取得する」と書かれている部分の実装詳細。
> Search API を優先し、個別リポジトリへフォールバックする。

## 優先度 1: GitHub Search API（推奨・最も効率的）

```typescript
// 組織全体から作成者と日付で検索（1回のAPI呼び出しで完了）
const query = `author:${username} created:${targetDate} type:pr org:standandforce`;

try {
  const searchResults = await searchIssuesOrPullRequests(query);
  const prs = searchResults.items;
} catch (error) {
  // Search API が利用できない場合はフォールバック
  console.log("Search API not available, falling back to repository list");
}
```

## 優先度 2: 個別リポジトリから取得（フォールバック）

Search API が使えない場合、以下の 5 つの DRESSCODE リポジトリから並列で検索:

| リポジトリ | 役割 |
|-----------|------|
| `standandforce/dresscode-backend` | バックエンド API（NestJS）|
| `standandforce/dresscode-frontend` | フロントエンド（React + TanStack Router）|
| `standandforce/dresscode-infrastructure` | Terraform 等 |
| `standandforce/dresscode-app-sdk` | アプリ SDK |
| `standandforce/dresscode-shadow-it-extension` | Shadow IT 拡張 |

```typescript
const TARGET_REPOS = [
  { owner: "standandforce", repo: "dresscode-backend" },
  { owner: "standandforce", repo: "dresscode-frontend" },
  { owner: "standandforce", repo: "dresscode-infrastructure" },
  { owner: "standandforce", repo: "dresscode-app-sdk" },
  { owner: "standandforce", repo: "dresscode-shadow-it-extension" },
];

const results = await Promise.all(
  TARGET_REPOS.map(({ owner, repo }) =>
    list_pull_requests({
      owner, repo,
      state: "all", sort: "created", direction: "desc",
      perPage: 20,
    })
  )
);

const myPRs = results.flat().filter(
  (pr) => pr.user.login === username && pr.created_at.startsWith(targetDate)
);
```

## ベストプラクティス

### データ取得の効率化

1. **最小限のデータ取得**: `perPage` は 10〜20 件、日付フィルタは API 側で可能なら API 側で
2. **並列処理**: 複数リポジトリの検索は `Promise.all` で並列実行
3. **早期リターン**: PR が 0 件なら即終了

### GitHub API レート制限

- Search API: 30 リクエスト/分
- REST API: 5000 リクエスト/時間
- 5 リポジトリ × 各 20 件 = 最大 100 件をチェック

### 大きなレスポンスの扱い

ツールが大きなファイルに出力した場合は `jq` でフィルタリング:

```bash
jq -r '.[] | select(.user.login == "gamonges" and (.created_at | startswith("2026-05-18"))) | {number, title, state, created_at, html_url}' /path/to/pr-list.txt
```

複数リポジトリの場合は個別処理してマージ:

```bash
for file in /path/to/backend-prs.txt /path/to/frontend-prs.txt ...; do
  jq -r '.[] | select(.user.login == "gamonges" and (.created_at | startswith("2026-05-18")))' "$file"
done | jq -s '.'
```

## PR 詳細情報の収集項目

各 PR について以下を収集する:

- タイトル、説明
- 変更ファイル数、追加/削除行数
- レビューコメント（`get_pull_request_comments` を使用）
- マージ状態
- 変更差分（必要な場合のみ取得）

## 注意事項

- プライベートリポジトリアクセス権限が必須
- 対象日に PR がなくても 5 リポジトリ全て確認する
- レビュー中の PR も分析対象に含める
- `scripts/daily-prs.sh`（同梱）が `gh api` ベースの最小実装を提供
