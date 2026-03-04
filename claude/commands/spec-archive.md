---
description: OpenSpec の変更提案を仕様にマージ、または plan.md から直接仕様を作成する（/spec-archive）
---

changes/ の変更提案を specs/ にマージし archive/ に移動する（完全フロー）、または plan.md から直接 specs/ に書き込む（簡易フロー）。

**重要**: 変更対象は `openspec/` ディレクトリのみに限定する（ソースコード、`tmp/` の変更禁止）。
**IMPORTANT**: Always respond in Japanese.

## パラメーター

`$ARGUMENTS` で change-name を指定できる。

- **指定あり（完全フロー）**: `openspec/changes/{change-name}/` を specs/ にマージする
- **指定なし（簡易フロー）**: `./tmp/plan.md` から直接 specs/ に ADDED のみで書き込む

## ワークフロー上の位置付け

| 前工程 | 本コマンド | 後工程 |
|--------|-----------|--------|
| `/spec-propose` 変更提案作成（完全フロー） | `/spec-archive` 仕様マージ | `/create-pr` |
| `/implement` 実装完了（簡易フロー） | `/spec-archive` 仕様作成 | `/create-pr` |

## 実行条件

### 完全フロー（`$ARGUMENTS` 指定時）

以下を確認する:

- `openspec/changes/$ARGUMENTS/` ディレクトリが存在すること
- `openspec/changes/$ARGUMENTS/specs/` 配下に delta spec が存在すること

### 簡易フロー（`$ARGUMENTS` 未指定時）

以下を確認する:

- `./tmp/plan.md` が存在すること

いずれの条件も満たされない場合:

- プロセスを即座に停止する
- どの条件が満たされていないかをユーザーに報告する
- 処理を続行しない

## 実行プロセス（完全フロー — change-name 指定時）

### フェーズ 1: 変更提案の読み込み

- [ ] `openspec/changes/{change-name}/` の存在確認
- [ ] `openspec/config.yaml` が存在する場合、プロジェクト固有のルールを読み込む
- [ ] delta spec（`changes/{change-name}/specs/{domain}/spec.md`）を読み込む
- [ ] 対応する `openspec/specs/{domain}/spec.md` を読み込む（存在しない場合は新規作成対象として扱う）

### フェーズ 2: delta spec のマージ

各ドメインの delta spec について以下を適用する:

- [ ] **ADDED**: `openspec/specs/{domain}/spec.md` に新規 Requirement を追記する
  - 既存 Requirement との重複をチェックし、重複がある場合はユーザーに確認する
- [ ] **MODIFIED**: 対象 Requirement ブロックを丸ごと置換する（部分更新禁止）
  - 対象 Requirement が specs/ に存在しない場合はエラーとして報告する
- [ ] **REMOVED**: 対象 Requirement ブロックを specs/ から削除する
  - 対象 Requirement が specs/ に存在しない場合は警告として報告する
- [ ] **RENAMED**: 対象 Requirement のセクション名を変更する
  - 対象 Requirement が specs/ に存在しない場合はエラーとして報告する
- [ ] `openspec/specs/{domain}/spec.md` の先頭に `最終更新: YYYY-MM-DD` を更新する

### フェーズ 3: アーカイブと整理

- [ ] `openspec/specs/{domain}/` ディレクトリが存在しない場合は作成する（`mkdir -p`）
- [ ] マージ済みの specs/ を書き込む
- [ ] `openspec/changes/{change-name}/` を `openspec/changes/archive/YYYY-MM-DD-{change-name}/` に移動する

### フェーズ 4: コミット

```bash
git add openspec/
git commit -m "docs(openspec): archive {change-name} into specs"
```

コミットに失敗した場合はユーザーに報告し、手動での対応を依頼する。

### フェーズ 5: 完了報告

以下の内容をユーザーに報告する:

- マージされた変更の概要（ADDED/MODIFIED/REMOVED/RENAMED の件数）
- 更新された specs/ ファイル一覧
- アーカイブ先のパス
- 次のステップの案内: `/create-pr` で PR を作成

---

## 実行プロセス（簡易フロー — change-name 未指定時）

### フェーズ 1: plan.md 読み込み・要件抽出

- [ ] `./tmp/plan.md` を読み込み、要件を把握する
- [ ] `openspec/config.yaml` が存在する場合、プロジェクト固有のルールを読み込む

### フェーズ 2: ドメイン名の決定

- [ ] plan.md の機能名からドメイン名を kebab-case で推定する
- [ ] 推定したドメイン名をユーザーに提示し確認する

### フェーズ 3: specs/ への書き込み

- [ ] `openspec/specs/{domain}/` ディレクトリの確認・自動作成（`mkdir -p`）
- [ ] GIVEN/WHEN/THEN 形式で **ADDED Requirements のみ** の仕様を生成する
  - 規範表現は SHALL/MUST/MUST NOT を使用する
  - 各 Requirement に最低1つの Scenario を含める
- [ ] `openspec/specs/{domain}/spec.md` に書き込む:
  - **新規作成**: フルフォーマットで作成（下記テンプレート参照）
  - **追記**: 既存の `## 要件` セクションに新しい Requirement を追加する。既存の内容は変更しない

**spec.md テンプレート（新規作成時）**:

```markdown
# {domain} 仕様

最終更新: YYYY-MM-DD

## 概要
[ドメインの概要・目的]

## 要件

### Requirement: {要件名}
{要件の説明。規範表現は SHALL/MUST/MUST NOT を使用}

#### Scenario: {シナリオ名}
- **GIVEN** [前提条件]
- **WHEN** [トリガー]
- **THEN** [期待結果]
- **AND** [追加条件]（任意）
```

### フェーズ 4: コミット

```bash
git add openspec/specs/
git commit -m "docs(openspec): add specs for {domain}"
```

コミットに失敗した場合はユーザーに報告し、手動での対応を依頼する。

### フェーズ 5: 完了報告

以下の内容をユーザーに報告する:

- 作成した仕様の概要（Requirement 数、ドメイン名）
- 作成されたファイルパス
- 次のステップの案内: `/create-pr` で PR を作成
