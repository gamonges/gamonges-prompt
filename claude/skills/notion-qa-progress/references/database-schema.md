# 製品タスク / Task データベーススキーマ

QA指摘データベースの詳細スキーマ情報です。

## データベース情報

- **データベース名**: 製品タスク / Task
- **Data Source URL**: `collection://56c6a371-180f-43e4-ba70-533465d6e0cb`

## ステータス選択肢

`ステータス` プロパティ（status型）の選択肢：

| グループ | ステータス値 |
|---------|-------------|
| **To Do** | Backlog, To Do, Need Planning |
| **In Progress** | In Designing, In Progress, Waiting For Review, In QA, Waiting For Release |
| **Complete** | Completed, Archived |

**フィルタ対象**: `"In Progress"` を完全一致で使用

## 主要プロパティ一覧

### 識別情報

| プロパティ名 | 型 | 説明 |
|-------------|-----|------|
| `userDefined:ID` | auto_increment_id | タスクID（DC-XXXX形式） |
| `タイトル` | title | タスク名 |
| `url` | - | ページURL |

### ステータス・分類

| プロパティ名 | 型 | 説明 |
|-------------|-----|------|
| `ステータス` | status | タスクステータス |
| `タスク種別` | select | 種別（🧐 QA指摘, 🐞 Bug, ☑️ タスク等） |
| `QA` | select | QA重要度（Critical, Major, Normal, Minor, Enhancement） |
| `QAステータス` | status | QA側のステータス |
| `チーム` | multi_select | 担当チーム（ITF, HRF, GAF等） |

### リレーション

| プロパティ名 | 型 | 説明 |
|-------------|-----|------|
| `親タスク` | relation | 親タスクへのリレーション |
| `サブアイテム` | relation | 子タスクへのリレーション |
| `GitHub PR` | relation | 関連PRへのリレーション |

### 不具合分類

| プロパティ名 | 型 | 選択肢例 |
|-------------|-----|---------|
| `不具合大分類（機能面）` | select | 仕様との相違, CRUD(台帳), 画面機能, UI表現, エラー表示, 権限, その他 |
| `不具合小分類（機能面）` | select | 実装が不足, 仕様の記載漏れ, 仕様が曖昧で実装誤り, 等 |

### 日付・メタデータ

| プロパティ名 | 型 | 説明 |
|-------------|-----|------|
| `date:日付:start` | date | 報告日 |
| `作成された時間` | created_time | 作成日時 |
| `最後に編集された時間` | last_edited_time | 最終編集日時 |
| `担当者` | person | 担当者 |
| `報告者` | person | 報告者 |

## サンプル親タスクURL

```
# Storage & Files: Boxのファイル・フォルダ毎の権限を台帳上で表示できる。（本番）
https://www.notion.so/2e53844e68a3804d938afcdde47bf305
```

## レスポンス例

`user-Notion:notion-fetch` のレスポンスから抽出する主要フィールド：

```json
{
  "properties": {
    "ステータス": "In Progress",
    "userDefined:ID": "DC-5905",
    "タイトル": "【フォルダ詳細>アカウント】内容...",
    "QA": "Major",
    "タスク種別": "🧐 QA指摘",
    "親タスク": ["https://www.notion.so/..."]
  }
}
```

## フィルタ条件

QA指摘でIn Progressのものを取得する場合：

1. `タスク種別` = `"🧐 QA指摘"`
2. `ステータス` = `"In Progress"`
3. `親タスク` に対象の親タスクURLが含まれる
