# 実装計画: コマンド改善 + OpenSpec 統合

## 概要

既存の開発ワークフローに OpenSpec の仕様永続化思想を取り入れ、新コマンド4つの作成と既存コマンド4つの改善を行う。すべての成果物は Markdown ファイル（プロンプト定義）であり、ソースコードの実装はない。

OpenSpec のフルワークフロー（changes/ → レビュー → specs/ マージ → archive/）を採用し、ADDED / MODIFIED / REMOVED / RENAMED の delta spec に対応する。簡易フロー（直接 specs/ 書き込み）と完全フロー（changes/ 経由）のハイブリッド運用を可能にする。

## 前提条件

- このリポジトリはプロンプト（Markdown）の管理が主目的
- コマンドは `claude/commands/*.md` に配置（YAML frontmatter + 実行手順）
- 仕様の永続化先は `openspec/specs/` にハードコード
- 変更提案は `openspec/changes/` に配置
- アーカイブは `openspec/changes/archive/` に配置
- `openspec/config.yaml` が存在する場合はプロジェクト固有のルールとして読み込む
- 既存コマンドの共通パターン（ガードレール、サブエージェント並列実行、日本語応答）を踏襲
- 新コマンドには `**IMPORTANT**: Always respond in Japanese.` を統一的に含める
- 既存コマンドの編集時にも、該当ファイルに日本語応答指示がなければ追記する

## OpenSpec ディレクトリ構造

```
openspec/
├── config.yaml                  ← プロジェクト固有の設定（任意）
├── specs/                       ← 仕様の正（Single Source of Truth）
│   ├── {domain}/
│   │   └── spec.md
│   └── ...
└── changes/                     ← 変更提案（作業領域）
    ├── {change-name}/
    │   ├── proposal.md          ← Why / What Changes / Impact
    │   ├── specs/               ← delta spec (ADDED/MODIFIED/REMOVED)
    │   │   └── {domain}/
    │   │       └── spec.md
    │   ├── design.md            ← 技術設計（plan.md から転記）
    │   └── tasks.md             ← 実装ステップ（plan.md から転記）
    └── archive/                 ← 完了した変更
        └── YYYY-MM-DD-{change-name}/
```

## ステップ間の依存関係

```
ステップ 1 (spec-propose) ─┐
                            ├─→ ステップ 2 (spec-archive) ※1に依存
                            ├─→ ステップ 4 (spec-check)   ※1のフォーマットに依存
ステップ 3 (design改善)  ───┘

ステップ 5 (revise改善)  ─── 独立
ステップ 6 (review+fix)  ─── 独立（ただし2ファイル同時変更必須）
ステップ 7 (status)      ─── 独立
ステップ 8 (implement改善) ── 独立

ステップ 9 (CLAUDE.md)   ─── 全ステップに依存（最後に実施）
```

並列実装可能な組み合わせ:
- ステップ 1 + ステップ 3 + ステップ 5 + ステップ 6 + ステップ 7 + ステップ 8
- ステップ 2 はステップ 1 完了後
- ステップ 4 はステップ 1 完了後

## 実装ステップ

### ステップ 1: `/spec-propose` コマンド新規作成（P1）

**変更対象ファイル**: `claude/commands/spec-propose.md`（新規作成）

**目的**: 実装完了後に plan.md の要点を `openspec/changes/{change-name}/` に変更提案として作成する。既存仕様の更新（MODIFIED/REMOVED）にも対応する。

**コマンド仕様**:
- 入力: `./tmp/plan.md`（実装済みの計画）
- 出力: `openspec/changes/{change-name}/` 配下に proposal.md, specs/, design.md, tasks.md
- 副作用: `git add && git commit`
- パラメーター: `$ARGUMENTS` で change-name を指定可（省略時は plan.md タイトルから推定）

**実行フロー**:
1. plan.md 読み込み・要件抽出
2. `openspec/config.yaml` が存在する場合、プロジェクト固有のルールを読み込む
3. change-name の決定（`$ARGUMENTS` or plan.md タイトルから kebab-case で推定、ユーザー確認）
4. `openspec/changes/{change-name}/` ディレクトリの作成（`mkdir -p`）
5. 既存 `openspec/specs/` をスキャンし、plan.md の変更が既存仕様に影響するか判定
6. 各アーティファクトを生成:
   - **proposal.md**: plan.md の概要・目的から Why / What Changes / Impact を抽出
   - **specs/{domain}/spec.md**: delta spec を生成（下記フォーマット参照）
   - **design.md**: plan.md の技術仕様・前提条件から転記
   - **tasks.md**: plan.md の実装ステップをチェックリスト形式に変換
7. git add/commit

**delta spec のフォーマット**:
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
```

**proposal.md のフォーマット**:
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

**ガードレール**:
- plan.md が存在しない場合 → STOP
- 同名の change が `openspec/changes/` に既に存在する場合 → ユーザーに確認（上書き or 別名）
- 変更対象は `openspec/changes/` ディレクトリのみに限定する
- `openspec/config.yaml` の rules が存在する場合、各アーティファクトの生成時にルールを適用する

---

### ステップ 2: `/spec-archive` コマンド新規作成（P1）

**依存**: ステップ 1（spec-propose）の delta spec フォーマットを前提とする。

**変更対象ファイル**: `claude/commands/spec-archive.md`（新規作成）

**目的**: changes/ の変更提案を specs/ にマージし、archive/ に移動する。または、簡易フローとして plan.md から直接 specs/ に書き込む。

**コマンド仕様**:
- 入力:
  - **完全フロー**: `$ARGUMENTS` で change-name を指定 → `openspec/changes/{change-name}/` を処理
  - **簡易フロー**: `$ARGUMENTS` 未指定 → `./tmp/plan.md` から直接 specs/ に ADDED のみで書き込み
- 出力: `openspec/specs/{domain}/spec.md`（更新）
- 副作用: `git add && git commit`

**実行フロー（完全フロー — change-name 指定時）**:
1. `openspec/changes/{change-name}/` の存在確認
2. `openspec/config.yaml` が存在する場合、ルールを読み込む
3. delta spec（`changes/{change-name}/specs/{domain}/spec.md`）を読み込む
4. 対応する `openspec/specs/{domain}/spec.md` を読み込む（存在しない場合は新規作成）
5. delta spec のマージ:
   - **ADDED**: specs/ に新規 Requirement を追記（重複チェック付き）
   - **MODIFIED**: 対象 Requirement ブロックを丸ごと置換
   - **REMOVED**: 対象 Requirement ブロックを削除
   - **RENAMED**: セクション名を変更
6. specs/ の `最終更新` 日付を更新
7. `openspec/changes/{change-name}/` → `openspec/changes/archive/YYYY-MM-DD-{change-name}/` に移動
8. git add/commit

**実行フロー（簡易フロー — change-name 未指定時）**:
1. `./tmp/plan.md` 読み込み・要件抽出
2. ドメイン名の決定（ユーザー確認）
3. `openspec/specs/{domain}/` ディレクトリの確認・自動作成
4. GIVEN/WHEN/THEN 形式で ADDED Requirements のみの仕様を生成
5. specs/{domain}/spec.md に書き込み:
   - **新規作成**: フルフォーマットで作成
   - **追記**: `## 要件` セクションに新しい Requirement を追加。既存は変更しない
6. git add/commit

**ガードレール**:
- 完全フロー: changes/{change-name}/ が存在しない場合 → STOP
- 簡易フロー: plan.md が存在しない場合 → STOP
- 変更対象は `openspec/` ディレクトリのみ（ソースコード、tmp/ の変更禁止）
- MODIFIED 時は Requirement ブロック全体を置換（部分更新禁止）

---

### ステップ 3: `/design` 改善 — research.md + openspec/specs/ 自動参照（P1）

**変更対象ファイル**: `claude/commands/design.md`（既存ファイル編集）

**変更内容**: フェーズ 1（コンテキスト読み込み）に research.md と openspec/specs/ の自動参照を追加。

**変更箇所**:
- フェーズ 1 に以下を追加:
  ```
  - [ ] `./tmp/research.md` が存在する場合、調査結果として追加コンテキストに含める
  - [ ] `openspec/specs/` が存在する場合、関連する既存仕様を参照し、新計画との整合性を考慮する
  - [ ] `openspec/config.yaml` が存在する場合、プロジェクト固有のルールを参照する
  ```
- 実行条件の注記に追加:
  ```
  - `./tmp/research.md`（任意）— `/ask` の調査結果。存在する場合は自動的に参照する
  - `openspec/specs/`（任意）— 既存の仕様ファイル。存在する場合は自動的に参照し、整合性を考慮する
  - `openspec/config.yaml`（任意）— プロジェクト固有のルール。存在する場合は計画策定に反映する
  ```

**影響範囲**: design.md のみ。他コマンドへの影響なし。

---

### ステップ 4: `/spec-check` コマンド新規作成（P2）

**依存**: ステップ 1（spec-propose）の spec フォーマットを前提とする。

**変更対象ファイル**: `claude/commands/spec-check.md`（新規作成）

**目的**: plan.md が既存仕様（`openspec/specs/`）と矛盾しないか網羅的に検証する。`/design` の自動参照（ステップ 3）はベストエフォートの参照であり、`/spec-check` はフォーマルな検証ステップとして機能する。

**コマンド仕様**:
- 入力: `./tmp/plan.md` + `openspec/specs/**/*.md`
- 出力: `./tmp/spec-check.md`（整合性レポート）
- 副作用: なし（分析のみ）

**実行フロー**:
1. plan.md 読み込み
2. `openspec/specs/` 配下の全 spec.md をスキャン
3. `openspec/changes/` 配下のアクティブな変更提案も考慮（並行変更の検出）
4. plan.md の変更内容と既存仕様の突合（サブエージェント並列）
5. 矛盾・影響・新規仕様必要箇所を特定
6. レポート出力（PASS / WARN / FAIL 判定）

**レポート構造**:
```markdown
# 仕様整合性チェック

## 影響を受ける仕様
- `openspec/specs/{domain}/spec.md` — [影響内容]

## 矛盾の検出
### 矛盾 1: [タイトル]
- **既存仕様**: openspec/specs/{domain}/spec.md:L{n} — [内容]
- **計画の記述**: tmp/plan.md:L{n} — [内容]
- **推奨**: [解決策]

## 並行変更との競合
- `openspec/changes/{change-name}/` — [競合内容]（アクティブな変更がある場合）

## 新規仕様が必要な領域
- [specs/ にまだ仕様がない機能]

## 判定: PASS / WARN / FAIL
```

**ガードレール**:
- plan.md が存在しない場合 → STOP
- `openspec/specs/` が存在しない場合 → 「仕様ディレクトリが未作成です。`/spec-archive` で最初の仕様を作成してください」と報告して終了
- ソースコード変更禁止

---

### ステップ 5: `/revise` 改善 — feedback.md 優先入力（P2）

**変更対象ファイル**: `claude/commands/revise.md`（既存ファイル編集）

**変更内容**: フィードバック入力のデフォルトを `feedback.md` 優先に変更。context.md はフォールバック。

**変更箇所**:
- 実行条件のフィードバック入力部分を変更:
  ```
  変更前: $ARGUMENTS（指定がない場合は ./tmp/context.md）
  変更後: $ARGUMENTS（指定がない場合は ./tmp/feedback.md → ./tmp/context.md の順で検索）
  ```
- フェーズ 2 の読み込みロジックを変更:
  ```
  - [ ] フィードバック入力の優先順位:
    1. `$ARGUMENTS` で指定されたファイル
    2. `./tmp/feedback.md`（存在する場合）
    3. `./tmp/context.md`（フォールバック）
  - [ ] `./tmp/plan-review.md` が存在する場合、追加フィードバックとして自動参照する
  ```

**影響範囲**: revise.md のみ。既存の使い方（context.md 利用）は維持される。

---

### ステップ 6: `/review` + `/fix` 改善 — 出力ディレクトリ構造化（P2）

**変更対象ファイル**:
- `claude/commands/review.md`（既存ファイル編集）
- `claude/commands/fix.md`（既存ファイル編集）

**変更内容（review.md）**:
- 出力パスを変更:
  ```
  変更前: ./tmp/review.md + ./tmp/{agent}-review.md
  変更後: ./tmp/review/unified.md + ./tmp/review/{agent}-review.md
  ```
- 出力フェーズに `mkdir -p ./tmp/review` を追加

**変更内容（fix.md）**:
- `./tmp/review.md` への参照を `./tmp/review/unified.md` に変更。対象箇所は以下の **4箇所**:
  - `fix.md:L25` — 参照条件説明
  - `fix.md:L34` — 実行条件
  - `fix.md:L85` — フェーズ1.2 の読み込み対象
  - `fix.md:L156` — フェーズ1.5 の統合対象

**影響範囲**: review.md と fix.md の2ファイル。CLAUDE.md のワークフロー説明も後で更新（ステップ 9）。

---

### ステップ 7: `/status` コマンド新規作成（P3）

**変更対象ファイル**: `claude/commands/status.md`（新規作成）

**目的**: ワークフローの現在地・進捗を一覧表示する。

**コマンド仕様**:
- 入力: tmp/ 配下のファイル群 + openspec/
- 出力: コンソール出力のみ（ファイル生成なし）
- 副作用: なし

**実行フロー**:
1. tmp/ 配下のファイル存在チェック（context.md, plan.md, feedback.md, review/, fix-plan.md, research.md）
2. plan.md が存在する場合、ステップ一覧と完了状況を抽出
3. openspec/specs/ の仕様ファイル数をカウント
4. openspec/changes/ のアクティブな変更提案を一覧表示
5. 現在のブランチ・PR 状態を確認
6. 推奨される次のアクションを提示

**出力フォーマット**:
```markdown
# ワークフロー状態

## ファイル状態
| ファイル | 状態 | 最終更新 |
|---------|------|---------|
| tmp/context.md | 存在 | YYYY-MM-DD HH:MM |
| tmp/plan.md | 存在 | YYYY-MM-DD HH:MM |
| ... | ... | ... |

## 実装進捗（plan.md）
- [x] ステップ 1: ...
- [ ] ステップ 2: ...
進捗: 1/N (XX%)

## 仕様状態（openspec/）
- specs/: N 個の仕様ファイル
- changes/: M 個のアクティブな変更提案
  - {change-name-1}: proposal + specs + design + tasks
  - {change-name-2}: proposal + specs

## 推奨アクション
→ [次に実行すべきコマンド]
```

**ガードレール**:
- ソースコード変更禁止
- ファイル生成禁止（コンソール出力のみ）

---

### ステップ 8: `/implement` 改善 — 進捗チェックボックス（P3）

**変更対象ファイル**: `claude/commands/implement.md`（既存ファイル編集）

**変更内容**: 各ステップ完了時に plan.md のチェックボックスを更新する指示を追加。

**変更箇所**:
- フェーズ 2（設計・小分割）に追加:
  ```
  - [ ] plan.md の各ステップに `- [ ]` チェックボックスがない場合は付与する
  ```
- フェーズ 3（実装ループ）の各ステップ完了時に追加:
  ```
  - [ ] 完了したステップの `- [ ]` を `- [x]` に更新する
  ```

**影響範囲**: implement.md のみ。plan.md のフォーマットに軽微な変更（チェックボックス付与）。

---

### ステップ 9: CLAUDE.md 更新

**依存**: 全ステップ完了後に実施。

**変更対象ファイル**: `CLAUDE.md`（既存ファイル編集）

**変更内容**:
- ワークフロー図の更新（2つのフローを記載）:
  ```
  ## 簡易フロー（新規仕様の追加）
  /ask → /design → /spec-check → /review-plan ⇄ /revise → /implement
    → /review → /fix → /implement fix-plan → /spec-archive → /create-pr

  ## 完全フロー（既存仕様の修正）
  /ask → /design → /spec-check → /review-plan ⇄ /revise → /implement
    → /review → /fix → /implement fix-plan → /spec-propose → (レビュー) → /spec-archive {change-name} → /create-pr
  ```
- コマンド一覧に `/spec-propose`, `/spec-archive`, `/spec-check`, `/status` を追加
- `openspec/` ディレクトリ構造の説明を追加（specs/, changes/, config.yaml）
- `/review` の出力パス記述を `./tmp/review/unified.md` に更新（CLAUDE.md:L48）
- `/design` の説明に research.md + openspec/specs/ + config.yaml 参照を追記（CLAUDE.md:L45）

---

## テスト方針

このリポジトリはプロンプト（Markdown）のみで構成されるため、自動テストの対象外。以下の手動検証を実施:

- [ ] 各コマンドの YAML frontmatter が正しいこと
- [ ] 新コマンドが既存コマンドの共通パターン（ガードレール、日本語応答、ファイル参照形式）を踏襲していること
- [ ] 新コマンドすべてに `**IMPORTANT**: Always respond in Japanese.` が含まれていること
- [ ] 既存コマンドの変更が後方互換性を維持していること（特に /revise のフォールバック）
- [ ] /review と /fix のパス変更が整合していること（fix.md の4箇所すべて更新）
- [ ] `/spec-propose` が ADDED/MODIFIED/REMOVED/RENAMED すべてに対応していること
- [ ] `/spec-archive` の完全フローと簡易フローが正しく分岐すること
- [ ] config.yaml が存在しない場合でも正常に動作すること

## 影響範囲

| ファイル | 変更種別 |
|---------|---------|
| `claude/commands/spec-propose.md` | 新規作成 |
| `claude/commands/spec-archive.md` | 新規作成 |
| `claude/commands/spec-check.md` | 新規作成 |
| `claude/commands/status.md` | 新規作成 |
| `claude/commands/design.md` | 編集（research.md + openspec/specs/ + config.yaml 自動参照追加） |
| `claude/commands/revise.md` | 編集（feedback.md 優先入力） |
| `claude/commands/review.md` | 編集（出力パス変更） |
| `claude/commands/fix.md` | 編集（参照パス変更 × 4箇所） |
| `claude/commands/implement.md` | 編集（チェックボックス追加） |
| `CLAUDE.md` | 編集（ワークフロー・コマンド一覧更新） |
