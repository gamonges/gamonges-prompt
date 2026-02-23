---
description: Daily Pull Request retrospective and learning extraction (/retrospective [date])
---

指定された日（または今日）に作成したプルリクエストを振り返り、学びと知見をまとめます。

**IMPORTANT**: Always respond in Japanese

## 概要

このコマンドは、あなたが作成したプルリクエストを振り返り、以下の観点で分析します：

- 実装内容の詳細な分析
- 設計パターンと実装の傾向
- 得られた学びと知見
- 今後のアクションアイテム
- 改善可能なポイント

## 実行条件

特別な条件はありませんが、以下を推奨します：

- GitHub リポジトリにアクセス可能であること
- 分析対象の日にプルリクエストが存在すること

## 実行プロセス

### Phase 1: プルリクエストの収集

**重要**: 効率的なデータ取得のため、以下の手順に従うこと

1. GitHub ユーザー情報を取得

   ```typescript
   // mcp_github_get_me を使用
   const user = await mcp_github_get_me();
   ```

2. **GitHub Search API または個別リポジトリから PR を取得**

   **優先度 1: GitHub Search API を使用（推奨・最も効率的）**

   ```typescript
   // 組織全体から作成者と日付で検索（1回のAPI呼び出しで完了）
   const query = `author:${username} created:${targetDate} type:pr org:standandforce`;

   try {
     // search_pull_requests または search_issues ツールを使用
     const searchResults = await searchIssuesOrPullRequests(query);
     const prs = searchResults.items; // PR一覧を取得
   } catch (error) {
     // Search APIが利用できない場合はフォールバック
     console.log("Search API not available, falling back to repository list");
   }
   ```

   **優先度 2: 個別リポジトリから取得（フォールバック）**

   Search API が使えない場合、以下の 5 つのリポジトリから検索：

   - `standandforce/dresscode-backend`
   - `standandforce/dresscode-frontend`
   - `standandforce/dresscode-infrastructure`
   - `standandforce/dresscode-app-sdk`
   - `standandforce/dresscode-shadow-it-extension`

   ```typescript
   // 対象リポジトリの定義
   const TARGET_REPOS = [
     { owner: "standandforce", repo: "dresscode-backend" },
     { owner: "standandforce", repo: "dresscode-frontend" },
     { owner: "standandforce", repo: "dresscode-infrastructure" },
     { owner: "standandforce", repo: "dresscode-app-sdk" },
     { owner: "standandforce", repo: "dresscode-shadow-it-extension" },
   ];

   // 各リポジトリから並列でPRを取得
   const allPRs = await Promise.all(
     TARGET_REPOS.map(async ({ owner, repo }) => {
       const prs = await list_pull_requests({
         owner,
         repo,
         state: "all",
         sort: "created",
         direction: "desc",
         perPage: 20, // 最新20件を取得
       });
       return prs;
     })
   );

   // 結果を平坦化し、日付でフィルタリング
   const filteredPRs = allPRs
     .flat()
     .filter(
       (pr) =>
         pr.user.login === username && pr.created_at.startsWith(targetDate)
     );
   ```

   **実装のポイント**:

   - まず Search API を試す（1 回の API 呼び出しで全リポジトリを検索）
   - Search API が使えない場合は個別リポジトリ方式にフォールバック
   - 個別方式では各リポジトリから最新 20 件の PR を取得（perPage: 20）
   - 並列処理で効率化（Promise.all）
   - 大きなレスポンスはファイルに出力されるため、jq コマンドでフィルタリング

3. 各 PR の詳細情報を収集:
   - タイトル、説明
   - 変更ファイル数、追加/削除行数
   - レビューコメント（`get_pull_request_comments` を使用）
   - マージ状態
   - 変更差分（必要な場合のみ取得）

**パフォーマンス最適化のポイント**:

- 複数リポジトリの場合、並列で取得
- PR が 0 件の場合は早期リターン
- 詳細情報は必要な PR のみ取得（日付フィルタ後）
- 大きなレスポンスを避けるため、API 呼び出しは最小限に

### Phase 2: 実装内容の分析

各プルリクエストについて以下を分析：

#### 技術的側面

- アーキテクチャパターン（レイヤードアーキテクチャ、DDD、クリーンアーキテクチャなど）
- 使用した設計パターン（Adapter、Repository、Value Object など）
- データフローと責務の分離
- テストカバレッジと品質保証の方法

#### コード品質

- 命名規則の一貫性
- コメントとドキュメンテーション
- エラーハンドリング
- パフォーマンスへの配慮

#### バックエンド・フロントエンド連携（該当する場合）

- API 設計の一貫性
- データ変換の責務配置
- 型安全性の確保
- UX/UI への配慮

### Phase 3: 学びと知見の抽出

以下の観点で学びをまとめる：

#### 実装の傾向と特徴

- あなたの実装スタイルの特徴
- よく使うパターンやアプローチ
- 強みとして現れている点

#### 得られた学び

- 新しく学んだ技術や手法
- うまくいった設計判断
- 効果的だったアプローチ

#### 改善の余地

- さらに良くできる点
- 今後取り組むべき課題
- 強化すべきスキル

### Phase 4: 振り返りレポートの生成

以下の構成でレポートを出力：

```markdown
# 📊 [日付] プルリクエスト振り返り

## 作成したプルリクエスト一覧

- PR #xxx: タイトル
  - 規模: +xxx/-xxx 行、x ファイル
  - 状態: [Open/Merged/Closed]
  - 概要

## 🎯 実装内容の分析

### 技術的な特徴

### アーキテクチャと設計パターン

### コード品質の観点

## 🌟 あなたの実装スタイルの特徴

### 強み

### 傾向

## 📚 得られた学び

### 技術的な学び

### 設計の学び

### プロセスの学び

## 💡 今後に活かせる観点

### すぐに活かせること

### 中長期的に取り組むこと

### 深掘りすべきトピック

## 🎓 今日の教訓
```

## 引数

- `date` (オプション): 振り返る日付（YYYY-MM-DD 形式）
  - 指定しない場合は今日の日付を使用
  - 例: `/retrospective 2025-11-17`

## 使用例

```bash
# 今日のPRを振り返る
/retrospective

# 特定の日のPRを振り返る
/retrospective 2025-11-17
```

## 対象リポジトリ

このコマンドは、以下の 5 つの DRESSCODE プロジェクトリポジトリから PR を検索します：

1. **dresscode-backend**: バックエンド API（NestJS）
2. **dresscode-frontend**: フロントエンド（React + TanStack Router）
3. **dresscode-infrastructure**: インフラストラクチャコード（Terraform 等）
4. **dresscode-app-sdk**: アプリ SDK
5. **dresscode-shadow-it-extension**: Shadow IT 拡張機能

### 実装手順

```typescript
// 5つのリポジトリから並列でPRを取得
const TARGET_REPOS = [
  { owner: "standandforce", repo: "dresscode-backend" },
  { owner: "standandforce", repo: "dresscode-frontend" },
  { owner: "standandforce", repo: "dresscode-infrastructure" },
  { owner: "standandforce", repo: "dresscode-app-sdk" },
  { owner: "standandforce", repo: "dresscode-shadow-it-extension" },
];

// 並列処理で効率化
const results = await Promise.all(
  TARGET_REPOS.map(({ owner, repo }) =>
    list_pull_requests({
      owner,
      repo,
      state: "all",
      sort: "created",
      direction: "desc",
      perPage: 20,
    })
  )
);

// 結果をマージしてフィルタリング
const myPRs = results
  .flat()
  .filter(
    (pr) => pr.user.login === username && pr.created_at.startsWith(targetDate)
  );
```

### 注意事項

- 各リポジトリから最新 20 件の PR を取得するため、最大 100 件の PR をチェック
- 対象日に PR が見つからない場合は、その旨をユーザーに通知
- レスポンスが大きい場合はファイルに出力されるため、jq コマンドでフィルタリング

## 振り返りのポイント

### 技術的観点

- 採用した設計パターンとその妥当性
- テスト戦略とカバレッジ
- パフォーマンスとスケーラビリティ
- セキュリティと堅牢性

### プロセス観点

- PR 作成までの時間
- レビューで指摘された点
- コミュニケーションの質
- ドキュメンテーションの充実度

### 成長観点

- 新しく習得した技術やパターン
- 過去の自分との比較
- チームへの貢献度
- 次回に活かせる改善点

## 出力形式

- マーク down 形式でわかりやすくフォーマット
- 絵文字を使用して視認性を向上
- コードブロックで具体例を提示
- セクションごとに整理された構成

## 期待される成果

このコマンドを定期的に実行することで：

- ✅ 自分の成長を可視化できる
- ✅ 実装パターンの傾向を把握できる
- ✅ 強みと改善点が明確になる
- ✅ チーム全体の知見として共有できる
- ✅ 継続的な学習習慣が身につく

## 実行時のベストプラクティス

### データ取得の効率化

1. **最小限のデータ取得**

   - `perPage` は必要最小限に（10〜20 件）
   - 日付フィルタリングは API 側で可能な場合は API 側で
   - 詳細情報は必要な PR のみ取得

2. **並列処理の活用**

   - 複数リポジトリの検索は並列実行
   - PR 詳細の取得も並列化可能

3. **早期リターン**
   - PR が 0 件の場合は即座に終了
   - 日付フィルタで除外された PR の詳細は取得しない

### GitHub API レート制限対策

- Search API: 30 リクエスト/分
- REST API: 5000 リクエスト/時間
- 大量の PR がある場合は適切にページング

### ファイル出力の扱い

- ツールが大きなファイルに出力した場合：
  1. `jq` や `grep` で必要な部分のみ抽出
  2. 対象日付でフィルタリング
  3. ユーザー名でフィルタリング

**実装例**:

```bash
# 単一リポジトリのPRファイルをフィルタリング
jq -r '.[] | select(.user.login == "gamonges" and (.created_at | startswith("2025-11-18"))) | {number: .number, title: .title, state: .state, created_at: .created_at, html_url: .html_url}' /path/to/pr-list.txt

# 複数リポジトリのPRを処理する場合
# 各リポジトリのファイルを個別に処理し、結果をマージ
for file in /path/to/backend-prs.txt /path/to/frontend-prs.txt ...; do
  jq -r '.[] | select(.user.login == "gamonges" and (.created_at | startswith("2025-11-18")))' "$file"
done | jq -s '.'  # 結果を配列にまとめる
```

## 注意事項

- プライベートリポジトリへのアクセス権限が必要（standandforce の 5 リポジトリ）
- GitHub API の制限に注意（上記レート制限参照）
- 5 つのリポジトリ全体から検索するため、API 呼び出しは 5 回発生
- 各リポジトリから最新 20 件ずつ取得するため、最大 100 件の PR をチェック
- レビュー中の PR も含めて分析対象とする
- **大量データのダウンロードを避け、必要な情報のみを効率的に取得すること**
- 対象日に PR がない場合でも、5 つのリポジトリすべてを確認する
