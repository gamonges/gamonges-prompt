---
description: 実装完了後の plan.md から OpenSpec 変更提案を作成する（/spec-propose）
---

実装完了後に plan.md の要点を `openspec/changes/{change-name}/` に変更提案として作成する。
新規仕様の追加（ADDED）だけでなく、既存仕様の更新（MODIFIED/REMOVED/RENAMED）にも対応する。

**重要**: 変更対象は `openspec/changes/` ディレクトリのみに限定する。ソースコード・`tmp/` の変更は禁止。
**IMPORTANT**: Always respond in Japanese.

## パラメーター

`$ARGUMENTS` で change-name を指定できる。省略時は plan.md のタイトルから kebab-case で推定する。

## ワークフロー上の位置付け

| 前工程 | 本コマンド | 後工程 |
|--------|-----------|--------|
| `/implement` 実装完了 | `/spec-propose` 変更提案作成 | レビュー → `/spec-archive {change-name}` 仕様マージ |

## 実行条件

以下のファイルが存在することを確認する:

- `./tmp/plan.md` — 実装済みの計画

ファイルが存在しない場合:

- プロセスを即座に停止する
- どの条件が満たされていないかをユーザーに報告する
- 処理を続行しない

## 実行プロセス

### フェーズ 1: plan.md 読み込み・要件抽出

- [ ] `./tmp/plan.md` を読み込み、概要・目的・実装ステップを把握する
- [ ] `openspec/config.yaml` が存在する場合、プロジェクト固有のルールを読み込む
  - `rules.proposal` — proposal.md の生成ルール
  - `rules.specs` — delta spec の生成ルール
  - `rules.design` — design.md の生成ルール
  - `rules.tasks` — tasks.md の生成ルール

### フェーズ 2: change-name の決定

- [ ] `$ARGUMENTS` が指定されている場合、その値を change-name とする
- [ ] 未指定の場合、plan.md のタイトル（`# 実装計画: {タイトル}`）から kebab-case で推定する
- [ ] 推定した change-name をユーザーに提示し確認する
- [ ] 同名の change が `openspec/changes/` に既に存在する場合、ユーザーに確認する（上書き or 別名）

### フェーズ 3: 既存仕様のスキャンと影響判定

- [ ] `openspec/specs/` が存在する場合、配下の全 `spec.md` をスキャンする
- [ ] plan.md の変更が既存仕様に影響するか判定する:
  - **MODIFIED**: 既存 Requirement の振る舞いが変わる場合
  - **REMOVED**: 既存 Requirement が不要になる場合
  - **RENAMED**: 既存 Requirement の名称が変わる場合
  - **ADDED**: 上記に該当しない新規 Requirement

### フェーズ 4: ドメイン名の決定

- [ ] 既存仕様への影響がある場合: 該当する既存ドメイン名を使用する
- [ ] 新規ドメインの場合: plan.md の機能名から kebab-case で推定し、ユーザーに確認する
- [ ] 複数ドメインにまたがる場合: ドメインごとに delta spec を分割する

### フェーズ 5: アーティファクトの生成

- [ ] `openspec/changes/{change-name}/` ディレクトリを作成する（`mkdir -p`）

#### 5.1 proposal.md の生成

plan.md の概要・目的から以下のフォーマットで生成する:

```markdown
# {change-name}

## Why
[変更の動機・背景]

## What Changes
[変更内容の概要]
- 対象 spec: openspec/specs/{domain}/spec.md
- コード領域: [影響を受けるコード領域]（判明している場合）

## Impact
[影響範囲・リスク・移行の考慮事項]
```

#### 5.2 delta spec の生成

`openspec/changes/{change-name}/specs/{domain}/spec.md` に以下のフォーマットで生成する:

```markdown
# Delta for {domain}

## ADDED Requirements

### Requirement: {要件名}
{要件の説明。規範表現は SHALL/MUST/MUST NOT を使用}

#### Scenario: {シナリオ名}
- **GIVEN** [前提条件]
- **WHEN** [トリガー]
- **THEN** [期待結果]
- **AND** [追加条件]（任意）

## MODIFIED Requirements

### Requirement: {既存要件名}
{変更後の要件の完全な記述 — 部分更新禁止、Requirement ブロック全体を記載}
（変更前: {変更前の値の要約}）

#### Scenario: {シナリオ名}
- **GIVEN** ...
- **WHEN** ...
- **THEN** ...

## REMOVED Requirements

### Requirement: {廃止する要件名}
（廃止理由: {理由}）

## RENAMED Requirements

### Requirement: {旧名} → {新名}
（変更理由: {理由}）
```

セクションに該当する変更がない場合、そのセクションは省略する。

`openspec/config.yaml` の `rules.specs` が存在する場合、そのルールに従って生成する。

#### 5.3 design.md の生成

plan.md の技術仕様・前提条件・アーキテクチャ判断を以下のフォーマットで転記する:

```markdown
# Design: {change-name}

## 技術仕様
[plan.md の前提条件・技術的な設計判断]

## アーキテクチャ
[レイヤー構成、責務分担、依存関係]

## 考慮事項
[パフォーマンス、セキュリティ、移行の考慮事項]
```

#### 5.4 tasks.md の生成

plan.md の実装ステップをチェックリスト形式に変換する:

```markdown
# Tasks: {change-name}

- [ ] ステップ 1: {ステップ名}
  - 変更対象: {ファイル一覧}
  - テスト: {テスト方針}
- [ ] ステップ 2: {ステップ名}
  ...
```

### フェーズ 6: コミット

```bash
git add openspec/changes/{change-name}/
git commit -m "docs(openspec): add change proposal {change-name}"
```

コミットに失敗した場合はユーザーに報告し、手動での対応を依頼する。

### フェーズ 7: 完了報告

以下の内容をユーザーに報告する:

- 作成した変更提案の概要
- 生成されたアーティファクト一覧
- 各 delta spec の概要（ADDED/MODIFIED/REMOVED/RENAMED の件数）
- 次のステップの案内:
  - 変更提案をレビューしてから `/spec-archive {change-name}` で仕様にマージする
  - レビューを省略する場合は直接 `/spec-archive {change-name}` を実行する
