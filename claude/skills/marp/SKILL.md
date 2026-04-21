---
name: marp
description: |
  アウトラインから dresscode テーマ準拠の Marp スライドを生成する。
  「Marp」「スライド作成」「スライド生成」「プレゼン作成」等のキーワードで使用。
  dresscode-marp-template リポジトリ内での実行を前提とする。
---

アウトラインから dresscode テーマ準拠の Marp スライドを生成する。

**⚠️ このスキルは dresscode-marp-template リポジトリ内で実行すること。**

**出力**: `./slides/YYYYMMDD_title.md`
**入力**: `$ARGUMENTS` または `./tmp/outline.md`
**参照**: `./references/dresscode-marp-rules.md`（dresscode テーマの生成ルール）
**IMPORTANT**: Always respond in Japanese.

## ワークフロー上の位置付け

| 前工程 | 本スキル | 後工程 |
|--------|---------|--------|
| `/outline` アウトライン生成 | `/marp` スライド生成 | Marp CLI でエクスポート（PDF/PPTX） |

## パラメーター

`$ARGUMENTS` で outline.md のパスを指定できる。省略時は `./tmp/outline.md` を使用する。

別プロジェクトで作成したアウトラインを使う場合は絶対パスで指定する:
```
/marp /Users/gamouhiroto/workspaces/other-project/tmp/outline.md
```

## 実行条件

以下のすべてを確認する:

- `$ARGUMENTS`（指定がない場合は `./tmp/outline.md`）— アウトライン
- **dresscode-marp-template リポジトリ内であること**: `marp.config.js` **かつ** `themes/dresscode.css` の両方が存在すること
  - どちらかが欠けている場合、プロセスを停止し「dresscode-marp-template リポジトリ内で実行してください」と報告する

ファイルが存在しない場合:

- プロセスを即座に停止する
- どの条件が満たされていないかをユーザーに報告する
- 処理を続行しない

## ワークフロー

### Phase 1: 入力読み込み

- [ ] アウトラインファイル（`$ARGUMENTS` または `./tmp/outline.md`）を読み込む
- [ ] メタ情報（ターゲット、核心メッセージ、制約、トーン）を把握する
- [ ] セクション構造とそれぞれの補足素材を整理する
- [ ] `./references/dresscode-marp-rules.md` を読み込み、生成ルールを把握する

### Phase 2: スライド設計

- [ ] 制約（時間）からスライド総数の目安を算出する（1分あたり1-2枚が目安）
- [ ] アウトラインの各セクションをスライドにマッピングする
  - セクションの情報密度に応じて1セクション = 1-3スライドに分割
  - 想定分量は参考値として扱い、実際の情報密度から判断する
- [ ] スライド構成を以下の順序で設計する:
  1. タイトルスライド
  2. アジェンダ / 自己紹介（必要に応じて）
  3. 本編セクション
  4. まとめスライド
  5. クロージング（Q&A / 感謝）

### Phase 3: テーマ・レイアウト割り当て

各スライドに以下を割り当てる:

- [ ] **テーマクラス**:
  - `title`: タイトル・クロージングスライド（`paginate: false` 併用）
  - `primary`: 通常のコンテンツスライド（デフォルト）
  - `secondary`: セクション区切り、コントラスト切り替え、表が多いスライド
- [ ] **レイアウトクラス**:
  - `.columns`: 比較・対比のコンテンツに2列レイアウト
  - `.columns-3`: 3つの概念を並列表示
  - `.center`: タイトルや強調テキスト
  - `.large` / `.small`: テキストサイズの調整
- [ ] **情報ボックス**:
  - `.highlight`: 核心メッセージや重要な教訓
  - `.info`: 技術的な補足情報
  - `.warning`: 注意事項やハマりポイント
  - `.success`: 成果や達成事項
  - `.error`: 失敗事例やアンチパターン

### Phase 4: Marp Markdown 生成

- [ ] YAML Front Matter を設定する:
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
- [ ] 各スライドを Markdown で生成する（スライド区切りは `---`）
- [ ] コンテンツ制約を適用する:
  - H1: 30文字以内
  - H2: 50文字以内
  - 箇条書き: 各項目80文字以内、1スライド7項目以内
  - 1スライドの総文字数: 300文字以下（コードブロック除く）
  - テーブル: 5列×8行以内
  - コードブロック: 20行以内、言語指定必須
- [ ] 画像は `../images/` からの相対パスで参照する
- [ ] 禁止要素を含めない: 複雑なHTML構造、インラインスタイル、外部リンク（参考資料セクション除く）

### Phase 5: 品質チェック・出力

- [ ] 品質チェックリストを実行する（下記参照）
- [ ] ファイル名を `YYYYMMDD_title.md` 形式で決定する（YYYYMMDD は本日の日付）
- [ ] `./slides/YYYYMMDD_title.md` に出力する
- [ ] ユーザーにスライド構成の概要（スライド数、セクション構成）を報告する
- [ ] Marp CLI でのプレビュー方法を案内する:
  ```bash
  npx @marp-team/marp-cli@latest --preview slides/YYYYMMDD_title.md
  ```

## 品質チェックリスト

出力完了後、以下を自己チェックする:

- [ ] YAML Front Matter が正しいか（marp: true, theme: dresscode, size: 16:9, paginate: true, footer: true, class: primary）
- [ ] タイトルスライドに `<!-- _class: title -->` と `<!-- paginate: false -->` があるか
- [ ] クロージングスライドに `<!-- _class: title -->` があるか
- [ ] 各スライドの文字数が300文字以下か（コードブロック除く）
- [ ] H1 が30文字以内、H2 が50文字以内か
- [ ] 箇条書きが1スライド7項目以内か
- [ ] テーブルが5列×8行以内か
- [ ] 画像パスが `../images/` で正しいか
- [ ] コードブロックに言語指定があるか
- [ ] コードブロックが20行以内か
- [ ] 禁止要素（複雑なHTML、インラインスタイル、外部リンク）がないか
- [ ] スライド間の流れがアウトラインの論理構造を反映しているか
