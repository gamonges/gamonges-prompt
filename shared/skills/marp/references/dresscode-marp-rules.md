# Dress Code Marp スライド生成ルール

dresscode-marp-template リポジトリのスライド生成に適用するルールセット。
元ファイル: `dresscode-marp-template/.cursor/rules/slidemarprules.mdc`

## 1. テンプレート使用規則

### 必須要件

- `YYYYMMDD_dresscode_template.md` をベースとして参照すること
- 生成されるスライドファイル名は `YYYYMMDD_タイトル.md` 形式とする
- 日付は実際の作成日（YYYY年MM月DD日）を使用する

### YAML Front Matter

```yaml
---
marp: true
theme: dresscode
size: 16:9
paginate: true
footer: true
class: primary
---
```

### ブランドカラー

- プライマリ背景: `#121D3E`（rgba(18, 29, 62, 0.95)）
- セカンダリ背景: `#ffffff`（rgba(255, 255, 255, 0.98)）
- フォントファミリー: `M PLUS 1p`, `Hiragino Kaku Gothic ProN`, `Yu Gothic UI`, `Meiryo UI`
- コードフォント: `SF Mono`, `Monaco`, `Cascadia Code`, `Fira Code`, `Consolas`

## 2. コンテンツ構成ルール

### スライド構造

1. **タイトルスライド** (`<!-- _class: title -->`)

   ```markdown
   <!-- _class: title -->
   <!-- paginate: false -->

   <div class="center">

   # プレゼンテーションタイトル

   Dress Code株式会社 / Product & Technology
   姓 名

   </div>
   ```

2. **基本スライド**
   - プライマリテーマ（デフォルト）: 濃紺背景
   - セカンダリテーマ: `<!-- _class: secondary -->` で白背景

3. **コンテンツスライド**
   - セクション番号とタイトルを含む
   - 適切な階層構造（H1, H2, H3）を使用

4. **まとめスライド**
   - 成果ボックス（`.success` クラス）を使用
   - 次のステップを明確に記載

5. **Q&A スライド** (`<!-- _class: title -->`)
   - 感謝の言葉とタイトルクラス使用

### 文字数制限

- **H1 タイトル**: 30文字以内
- **H2 サブタイトル**: 50文字以内
- **箇条書き各項目**: 80文字以内
- **1スライドの総文字数**: 300文字以内（コードブロック除く）

### レイアウト制限

- **1スライドの箇条書き項目**: 最大7項目
- **表の列数**: 最大5列
- **表の行数**: 最大8行（ヘッダー含む）

## 3. テーマクラス使用ガイド

### 基本テーマ

| クラス | 背景 | テキスト | 用途 |
|--------|------|----------|------|
| `primary`（デフォルト） | ダークネイビー (#121D3E) | 白 | 通常スライド |
| `secondary` | 白 | 黒 | コントラスト切り替え、表が多いスライド |
| `title` | 特殊 | 白 | タイトル・クロージング（ページ番号非表示） |

### レイアウトクラス

#### 2カラムレイアウト（`.columns`）

```html
<div class="columns">
  <div class="column">## 左カラム</div>
  <div class="column">## 右カラム</div>
</div>
```

#### 3カラムレイアウト（`.columns-3`）

```html
<div class="columns-3">
  <div class="column">## カラム1</div>
  <div class="column">## カラム2</div>
  <div class="column">## カラム3</div>
</div>
```

#### テキスト装飾

- `.center`: 中央揃え
- `.large`: 大きなテキスト（1.2em）
- `.small`: 小さなテキスト（0.9em、透明度0.8）

### 情報ボックス

```html
<div class="highlight">
  🎯 <strong>キーポイント</strong>: 重要な情報をハイライト表示
</div>

<div class="info">
  💡 <strong>情報</strong>: 一般的な情報
</div>

<div class="warning">
  ⚠️ <strong>注意</strong>: 注意が必要な事項
</div>

<div class="success">
  ✅ <strong>成功</strong>: 成功メッセージ
</div>

<div class="error">
  ❌ <strong>エラー</strong>: エラーメッセージ
</div>
```

| クラス | 色 | 用途 |
|--------|-----|------|
| `.highlight` | 紫（#a855f7） | 核心メッセージ、重要な教訓 |
| `.info` | 青（#3b82f6） | 技術的な補足情報 |
| `.warning` | 黄（#f59e0b） | 注意事項、ハマりポイント |
| `.success` | 緑（#22c55e） | 成果、達成事項 |
| `.error` | 赤（#ef4444） | 失敗事例、アンチパターン |

## 4. 画像使用ルール

### 配置規則

- 全ての画像は `images/` ディレクトリに配置
- スライドからの相対パス: `../images/`
- 画像ファイル名は英数字とアンダースコアのみ使用

### 利用可能な画像

- **背景画像**: `background.png`
- **プライマリテーマ用ロゴ**: `LogoDressCode_onBlue.png`
- **セカンダリテーマ用ロゴ**: `LogoDressCode_onWhite.png`

### サイズ指定

```markdown
![width:600px](../images/filename.png)  <!-- コンテンツ画像（大） -->
![width:300px](../images/filename.png)  <!-- コンテンツ画像（小） -->
![width:24px](../images/logo.png)       <!-- アイコン/ロゴ -->
```

### 画像キャプション

画像の下に斜体でキャプションを記載: `*図X: 説明文*`

## 5. コードブロック規則

### 言語指定

- TypeScript: `typescript` または `ts`
- JavaScript: `javascript` または `js`
- Python: `python` または `py`
- その他: 適切な言語識別子を使用

### コード内容

- 実際に動作するコードを記載
- コメントで説明を補完
- **1ブロック20行以内**

## 6. 表のスタイリング

```markdown
| 項目         | 説明                   | ステータス |
| ------------ | ---------------------- | ---------- |
| デザイン     | ブランド統一された外観 | ✅ 完了    |
| レスポンシブ | 様々な画面サイズに対応 | ✅ 完了    |
```

- 最大5列×8行
- secondary テーマでの使用を推奨（表の色がセカンダリテキスト色で固定のため）

## 7. ページネーション・フッター

### ページネーション

- `paginate: true` で有効
- タイトルスライドのみ `<!-- paginate: false -->` で無効化

### フッター

- `footer: true` で有効
- テーマに応じて適切なロゴが自動表示:
  - プライマリテーマ: 白ロゴ（青背景用）
  - セカンダリテーマ: 青ロゴ（白背景用）

## 8. フォーマット制限

### 使用可能な要素

- 見出し（H1〜H6、ただしH1〜H3推奨）
- 箇条書き（番号付き・記号付き）
- 表
- コードブロック
- 引用
- 強調（**太字**、_斜体_）
- 画像
- 情報ボックス（`.highlight`, `.info`, `.warning`, `.success`, `.error`）
- HTML の div とクラス（レイアウト用）

### 使用禁止要素

- 複雑な HTML 構造
- インラインスタイル
- 外部リンク（参考資料セクション除く）

## 9. プロジェクト構造

```
dresscode-marp-template/
├── images/                     # 画像ファイル
│   ├── background.png          # 背景画像
│   ├── LogoDressCode_onBlue.png # 青背景用ロゴ
│   └── LogoDressCode_onWhite.png # 白背景用ロゴ
├── slides/                     # スライドファイル
│   └── YYYYMMDD_dresscode_template.md # テンプレート
├── themes/                     # テーマファイル
│   └── dresscode.css          # Dress Code テーマ
├── public/                     # 出力先
└── marp.config.js             # Marp 設定
```

## 10. 注意事項

- 日本語と英語の混在時は適切なスペーシングを行う
- 専門用語には必要に応じて説明を付加する
- ブランドガイドラインに沿った表現を使用する
- テーマの使い分けでコンテンツの重要度を表現する
