---
name: implementing-figma-design
description: Figmaデザインをピクセルパーフェクトなコードに変換する。Figmaファイルからの実装時、「デザインを実装して」「コードを生成して」「コンポーネントを作って」「Figmaデザインを構築して」といったリクエスト時、FigmaのURLが提供された時、またはFigmaの仕様に合わせたコンポーネント作成を依頼された時に使用。Figma MCPサーバーへの接続が必要。
---

# Figma デザインの実装

Figma デザインをピクセルパーフェクトな本番用コードに変換するためのワークフロー。

## 前提条件

- Figma MCP サーバーに接続済み（`figma` または `figma-desktop`）
- Figma の URL 形式: `https://figma.com/design/:fileKey/:fileName?node-id=1-2`
- **または** `figma-desktop` の場合: Figma デスクトップアプリでノードを選択（URL 不要）

## 必須ワークフロー

**この順番で実行すること。ステップを飛ばさないこと。**

### ステップ 1: ノード ID の取得

#### 方法 A: Figma の URL から抽出

URL `https://figma.com/design/:fileKey/:fileName?node-id=1-2` から抽出:

- **ファイルキー:** `:fileKey`（`/design/` の後のセグメント）
- **ノード ID:** `1-2`（`node-id` クエリパラメータの値）

**注意:** `figma-desktop` MCP では `fileKey` は不要。現在開いているファイルが自動的に使用される。

#### 方法 B: 現在の選択を使用（figma-desktop のみ）

開いている Figma ファイルで選択中のノードが自動的に使用される。

### ステップ 2: デザインコンテキストの取得

```
figma:get_design_context(fileKey=":fileKey", nodeId="1-2")
```

デスクトップ版の場合:

```
figma-desktop:get_design_context(nodeId="1-2")
```

取得できる情報: レイアウトプロパティ、タイポグラフィ、カラー、コンポーネント構造、スペーシング

**レスポンスが切り詰められた場合:**

1. `figma:get_metadata(fileKey=":fileKey", nodeId="1-2")` でノードマップを取得
2. 子ノードを個別に `figma:get_design_context` で取得

### ステップ 3: ビジュアルリファレンスの取得

```
figma:get_screenshot(fileKey=":fileKey", nodeId="1-2")
```

このスクリーンショットがビジュアル検証の基準となる。

### ステップ 4: 必要なアセットのダウンロード

Figma MCP サーバーからアセット（画像、アイコン、SVG）をダウンロード。

**アセットのルール:**

- `localhost` ソースが提供された場合はそのまま使用
- 新しいアイコンパッケージをインポートしない（Figma のペイロードからのアセットのみ使用）
- `localhost` ソースがある場合はプレースホルダーを作成しない

### ステップ 5: プロジェクトの規約に変換

- Figma MCP の出力はデザイン表現として扱い、最終的なコードスタイルとしない
- Tailwind クラスをプロジェクトのデザインシステムトークンに置き換え
- 機能を重複させず、既存コンポーネントを再利用
- プロジェクトのルーティング、状態管理、データ取得パターンを尊重

### ステップ 6: 1:1 のビジュアル再現を達成

- Figma のデザイントークンを可能な限り使用
- 競合が発生した場合はプロジェクトのトークンを優先し、スペーシングで調整
- WCAG アクセシビリティ要件に準拠

### ステップ 7: Figma との照合

**チェックリスト:**

- [ ] レイアウトが一致（スペーシング、配置、サイズ）
- [ ] タイポグラフィが一致（フォント、サイズ、ウェイト、行間）
- [ ] カラーが完全に一致
- [ ] インタラクティブステートが動作（hover, active, disabled）
- [ ] レスポンシブ動作が Figma の制約に従う
- [ ] アセットが正しく表示
- [ ] アクセシビリティ基準を満たす

## 実装ルール

### コンポーネントの整理

- プロジェクトのデザインシステムディレクトリに配置
- プロジェクトの命名規則に従う
- 動的な値以外ではインラインスタイルを避ける

### デザインシステムとの統合

- 可能な限り既存のデザインシステムコンポーネントを使用
- Figma トークンをプロジェクトトークンにマッピング
- 新規作成より既存コンポーネントの拡張を優先

### コード品質

- ハードコードされた値は定数やトークンに抽出
- コンポーネントは組み合わせ可能で再利用可能に
- TypeScript 型と JSDoc コメントを追加

## 例

### 例 1: ボタンコンポーネント

ユーザー: 「この Figma ボタンを実装して: https://figma.com/design/kL9xQn2VwM8pYrTb4ZcHjF/DesignSystem?node-id=42-15」

**アクション:**

1. fileKey=`kL9xQn2VwM8pYrTb4ZcHjF`, nodeId=`42-15` を抽出
2. `figma:get_design_context(fileKey="kL9xQn2VwM8pYrTb4ZcHjF", nodeId="42-15")` を実行
3. `figma:get_screenshot(fileKey="kL9xQn2VwM8pYrTb4ZcHjF", nodeId="42-15")` を実行
4. アセットエンドポイントからボタンアイコンをダウンロード
5. 既存のボタンコンポーネントを確認 → 拡張または新規作成
6. Figma カラーをプロジェクトトークンにマッピング
7. スクリーンショットと照合

### 例 2: ダッシュボードレイアウト

ユーザー: 「このダッシュボードを作って: https://figma.com/design/pR8mNv5KqXzGwY2JtCfL4D/Dashboard?node-id=10-5」

**アクション:**

1. fileKey=`pR8mNv5KqXzGwY2JtCfL4D`, nodeId=`10-5` を抽出
2. `figma:get_metadata` でページ構造を把握
3. セクション（ヘッダー、サイドバー、コンテンツ、カード）と子ノード ID を特定
4. 各主要セクションで `figma:get_design_context` を実行
5. ページ全体の `figma:get_screenshot` を実行
6. 全アセットをダウンロード
7. プロジェクトのレイアウトプリミティブでレイアウトを構築
8. レスポンシブ動作を検証

## よくある問題

| 問題                       | 解決策                                                                     |
| -------------------------- | -------------------------------------------------------------------------- |
| Figma 出力が切り詰められる | まず `figma:get_metadata` を使い、ノードを個別に取得                       |
| デザインが一致しない       | スクリーンショットと比較し、スペーシング/カラー/タイポグラフィ値を確認     |
| アセットが読み込まれない   | MCP アセットエンドポイントのアクセス可否を確認、`localhost` URL を直接使用 |
| トークン値が異なる         | プロジェクトトークンを優先し、スペーシングで視覚的忠実度を維持             |

## 参考リソース

- [Figma MCP サーバードキュメント](https://developers.figma.com/docs/figma-mcp-server/)
- [Figma MCP サーバーのツールとプロンプト](https://developers.figma.com/docs/figma-mcp-server/tools-and-prompts/)
- [Figma 変数とデザイントークン](https://help.figma.com/hc/en-us/articles/15339657135383-Guide-to-variables-in-Figma)
