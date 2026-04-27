---
name: document-spec
description: 既存実装ファイル群から openspec spec を直接生成する（/document-spec --domain <name> --files "..."）
---

未文書化の既存実装を openspec 仕様として書き起こす。`/spec-archive`（plan.md ベース）と `/spec-propose`（proposal フロー）の中間を埋める用途。

**重要**: `openspec/specs/` 配下のみを変更する。ソースコードは変更しない。
**規約**: CLAUDE.md の Skills 共通規約に従う
## パラメーター

引数として以下を指定する（対話的に取得することも可能）:

- `--domain <name>`: 仕様化対象のドメイン名（kebab-case）
- `--files "path1,path2,..."`: 解析対象の実装ファイル群（カンマ区切り、リポジトリルートからの相対パス）

例:
- `/document-spec --domain accesses-ingestion --files "v2/src/it-force/api/shadow-it/usecase/create-traceable-app-visit-history.usecase.ts,v2/src/it-force/api/shadow-it/repository/visit.repository.ts"`

引数が未指定の場合、対話的に確認する。

## ワークフロー上の位置付け

| 用途 | スキル | 入力源 |
|------|--------|--------|
| 新機能の仕様化（plan からの逆算） | `/spec-archive` 簡易フロー | `tmp/plan.md` |
| 提案ベースの変更管理 | `/spec-propose` → `/spec-archive` 完全フロー | `openspec/changes/{name}/` |
| **既存実装の文書化** | **`/document-spec`** | **指定された実装ファイル群** |

## 実行条件

- `--domain` と `--files` の双方が決定していること
- 指定された各ファイルが実在すること
- `openspec/specs/` ディレクトリが存在すること（無ければエラー）

条件が満たされない場合は即座に停止し、ユーザーに報告する。

## 実行プロセス

### フェーズ 1: 入力の確認とファイル読み込み

- [ ] `--domain` の値を確認（kebab-case、既存 `openspec/specs/<domain>/` との衝突チェック）
  - 衝突がある場合は AskUserQuestion で「マージ追記 / 別 domain にリネーム / 中止」を選択
- [ ] `--files` で指定された各ファイルを読み込む
- [ ] `openspec/config.yaml` が存在する場合、プロジェクト固有のルール（規範表現の制約等）を読み込む

### フェーズ 2: ビジネスルール抽出

各ファイルからビジネスルールを抽出する:

- [ ] 入出力の型シグネチャ（DTO、Entity、Repository インターフェース）
- [ ] 分岐ロジック（if / switch / guard 句）から導出される条件
- [ ] エラーケース（throw / Result.err / カスタムエラークラス）
- [ ] 副作用（DB 書き込み、外部 API 呼び出し、イベント発火）
- [ ] バリデーションルール（class-validator / zod / 手動 assert）

抽出結果を「Given / When / Then」形式の Scenario に整形する。

### フェーズ 3: ユーザー確認（必要に応じて）

- [ ] 抽出したビジネスルールの一覧をユーザーに提示
- [ ] 「この粒度で Requirement を構成してよいか」を確認
- [ ] 過不足があればユーザー指示で追加 / 削除

### フェーズ 4: spec.md の生成

`openspec/specs/<domain>/spec.md` を以下のテンプレートで生成する:

```markdown
# {domain} Specification

最終更新: YYYY-MM-DD

## Purpose
[ドメインの概要・目的、対象ファイルの責務範囲]

## Requirements

### Requirement: {要件名}
{要件の説明。規範表現は SHALL/MUST/MUST NOT を使用}

#### Scenario: {シナリオ名}
- **GIVEN** [前提条件]
- **WHEN** [トリガー]
- **THEN** [期待結果]
- **AND** [追加条件]（任意）
```

既存 `openspec/specs/<domain>/spec.md` がある場合（フェーズ 1 でマージ追記を選択した場合）、`## Requirements` セクションに新規 Requirement を追記する。既存の内容は変更しない。

### フェーズ 5: 検証

`openspec validate` で生成した仕様が strict モードを通過するか確認する:

```bash
pnpm exec openspec validate {domain} --strict
```

- 検証エラーが出た場合は次のフェーズに進まず、テンプレとの差異を修正する
- `pnpm exec openspec` が利用不可な環境では警告のみ表示してスキップする

### フェーズ 6: 完了報告

ユーザーに以下を報告する:

- 生成 / 追記された Requirement 数
- 出力先パス（`openspec/specs/<domain>/spec.md`）
- validate 結果（パス / スキップ / エラー）
- 次のステップ案内: `/create-pr` または `/spec-propose` で変更提案化

## 注意事項

- 既存実装の挙動を **そのまま** 仕様化する。改善案や TODO は本スキルの責務外（必要なら `/design` で別途プランニング）
- 抽出粒度は「Requirement = 1 機能、Scenario = 1 ユースケース」を目安にする
- ビジネスルールが複数ファイルに跨がる場合、`--files` に全部指定して一括で読み解く
