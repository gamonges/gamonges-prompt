---
name: notion-qa-progress
description: NotionのQA指摘データベースから「In Progress」ステータスのタスクを取得する。QA対応状況の確認、対応すべきタスクの一覧取得時に使用。
---

# Notion QA指摘取得スキル

「In Progress」ステータスのQA指摘を効率的に取得します。

## When to Use

- QA対応状況を確認するとき
- 現在対応中のタスク一覧を取得するとき
- 特定の価値（親タスク）に紐づくQA指摘の進捗を確認するとき

## 推奨アプローチ（効率的）

### 方法A: フィルター済みビューをクエリ（最も正確、1回のAPI呼び出し）

**事前準備**: Notionで「In Progress」フィルターを設定したビューを作成

1. Notionで対象データベースを開く
2. 新しいビューを作成し「ステータス = In Progress」でフィルター
3. ビューURLをコピー（形式: `https://www.notion.so/{workspace}/{db-name}-{db-id}?v={view-id}`）

```
user-Notion:notion-query-database-view
引数: { "view_url": "<フィルター済みビューURL>" }
```

**メリット**: 1回のMCP承認で正確にIn Progressのみ取得

### 方法B: セマンティック検索（1回のAPI呼び出し、おおよその結果）

`user-Notion:notion-search` でデータソースを指定して検索：

```
user-Notion:notion-search
引数: {
  "query": "In Progress QA指摘 <親タスク名のキーワード>",
  "data_source_url": "collection://56c6a371-180f-43e4-ba70-533465d6e0cb"
}
```

**メリット**: 1回のMCP承認で複数の結果を取得可能
**注意**: セマンティック検索のため、ステータスによる正確なフィルタは保証されない

## 代替アプローチ（個別取得）

検索やビュークエリで十分な結果が得られない場合のフォールバック：

```
QA指摘取得進捗：
- [ ] Step 1: 親タスクページを取得（notion-fetch）
- [ ] Step 2: サブアイテムURLを抽出
- [ ] Step 3: 各サブアイテムを並列取得（複数回のMCP承認が必要）
- [ ] Step 4: 「In Progress」をフィルタ
- [ ] Step 5: 結果をサマリー出力
```

### Step 1: 親タスクページを取得

```
user-Notion:notion-fetch
引数: { "id": "<親タスクのURL>" }
```

レスポンスの `properties.サブアイテム` からURLリストを取得。

### Step 3: サブアイテム取得

サブアイテムURLごとに `user-Notion:notion-fetch` を実行。
※ 各呼び出しでMCP承認が必要になる点に注意

## 結果出力フォーマット

```markdown
## In Progressのタスク一覧（N件）

| ID | タイトル | QA重要度 | URL |
|----|---------|---------|-----|
| DC-XXXX | 【機能】内容 | Major | URL |
```

## 主要プロパティ

| プロパティ | 説明 |
|-----------|------|
| `ステータス` | タスクステータス（To Do, In Progress, Completed等） |
| `userDefined:ID` | タスクID（DC-XXXX形式） |
| `タイトル` | タスク名 |
| `QA` | QA重要度（Critical, Major, Normal, Minor） |
| `タスク種別` | 「🧐 QA指摘」でフィルタ可能 |

**詳細スキーマ**: [references/database-schema.md](references/database-schema.md) 参照

## データソース情報

- **製品タスクDB**: `collection://56c6a371-180f-43e4-ba70-533465d6e0cb`
- **サンプル親タスク**: `https://www.notion.so/2e53844e68a3804d938afcdde47bf305`
