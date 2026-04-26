---
description: AI code review using specialized subagents (/review)
---

Perform comprehensive code review using specialized AI agents working in parallel.

**IMPORTANT**: Never modify source files — only output review files.
**IMPORTANT**: Always respond in Japanese.

## Execution Conditions

- Pull Request exists for the current branch (draft or opened), OR the user appended a PR link or number after the command.
- If not met: stop immediately, notify the user, do not proceed.

## Subagent Output Template

Each subagent MUST write its review to `./tmp/review/{agent-name}-review.md`.

**File path rules**: Always use relative paths from project root with `L{number}` line format (e.g. `src/apps/app/src/routes/_staff/file.tsx:L42-50`). Never use bare file names.

```markdown
# {Agent Name} Review — PR #{number}

## レビュー結果

### ❌ Critical Issues

1. **問題タイトル**
   - **確信度**: High / Medium / Low
   - **カテゴリ**: correctness | security | performance | design | naming | accessibility | testing | consistency
   - **ファイル**: `src/full/path/to/file.tsx:L42-50`
   - **該当箇所**: 具体的なコードや説明
   - **理由**: なぜ問題か
   - **修正案**: 具体的な修正方法（コード例付き）

### ⚠️ Minor Issues

(same format)

### ℹ️ Info & Questions

(same format)

### ✅ Good Points

1. **良い実装のタイトル** — 具体的な説明
```

**Notes**:
- 該当なしのセクションは省略すること
- Low confidence の指摘は ⚠️ Minor 以下に分類すること

## Review Agents

| Agent | Role |
|-------|------|
| **pm-reviewer** | 要件整合性、受入基準、UX 一貫性 |
| **code-quality-reviewer** | テスト品質、命名、DRY、設計原則、エッジケース（言語・フレームワーク非依存の汎用品質） |
| **frontend-reviewer** | UI コンポーネント、state 管理、パフォーマンス、React hooks、TanStack Router/Query、Web 標準、アクセシビリティ、デザインシステム準拠 |
| **backend-reviewer** | サーバーサイドアーキテクチャ、API 設計、データ整合性、CQRS 検証、テナント分離、エラーハンドリング設計 |
| **database-reviewer** | PostgreSQL、Prisma ORM、マイグレーション、クエリ最適化 |
| **infrastructure-reviewer** | AWS、Terraform、CI/CD |

## Execution Process

### Phase 1: Collect PR Context

```bash
# Verify PR exists
current_branch=$(git branch --show-current)
pr_number=$(gh pr list --head "$current_branch" --state all --json number --jq '.[0].number')
if [ "$pr_number" = "null" ] || [ -z "$pr_number" ]; then
    echo "No PR found for branch: $current_branch"
    exit 1
fi

# Collect metadata & diff
base_branch=$(gh pr view "$pr_number" --json baseRefName --jq '.baseRefName')
pr_title=$(gh pr view "$pr_number" --json title --jq '.title')
pr_body=$(gh pr view "$pr_number" --json body --jq '.body')
changed_files=$(git diff --name-only "${base_branch}...HEAD")
full_diff=$(git diff "${base_branch}...HEAD")
commit_log=$(git log --oneline "${base_branch}...HEAD")
diff_lines=$(git diff --stat "${base_branch}...HEAD" | tail -1)
```

### Phase 1.6: Collect CI Status

PR の CI チェック結果を取得し、失敗があれば `tmp/review/_ci-failures.md` に記録する。後続の Phase 4 で unified.md の先頭セクションとして提示する。

```bash
mkdir -p tmp/review
ci_checks=$(gh pr checks "$pr_number" --json name,state,bucket,link 2>/dev/null || echo "[]")
failed_checks=$(echo "$ci_checks" | jq -c '.[] | select(.bucket == "fail")')
```

`failed_checks` が空でない場合のみ以下を実行:

1. 各 job の `link` フィールドから run ID を抽出（URL パターン `/runs/<id>/` の `<id>` 部分）
2. `gh run view <run-id> --log-failed | tail -n 30` で末尾 30 行を取得
3. job 名 / bucket / link / log の末尾 30 行をまとめて `tmp/review/_ci-failures.md` に保存

`gh pr checks` 実行不可（gh 未認証等）または空配列の場合は `_ci-failures.md` を作成しないだけで処理は続行する（CI 失敗未検出として扱う）。

### Phase 1.5: Detect Project Type

Detect the project type to determine which agents and rules to use.

#### Detection logic (priority order)

**Step 1: package.json dependencies (highest priority)**

Check the root or primary `package.json` for framework dependencies:

| Dependency | Frontend | Backend |
|-----------|----------|---------|
| `@nestjs/core` in dependencies | — | ✅ |
| `react` in dependencies | ✅ | — |

For monorepos with multiple `package.json` files, check the root one first, then the primary app package.

**Step 2: CLAUDE.md keywords (supplementary)**

If Step 1 is inconclusive, scan `.claude/CLAUDE.md` for framework keywords:

| Keyword in CLAUDE.md | Frontend | Backend |
|---------------------|----------|---------|
| "NestJS" or "Prisma" | — | ✅ |
| "React" or "TanStack" | ✅ | — |

**Step 3: Directory structure (final fallback)**

| Signal | Frontend | Backend |
|--------|----------|---------|
| `src/apps/` directory exists | ✅ | — |
| `v2/src/` directory exists | — | ✅ |

**If detection fails**: Set `project_type = unknown` and use all agents as candidates (equivalent to legacy behavior).

Result: `project_type` = `frontend` | `backend` | `unknown`

### Phase 2: PR Overview Analysis

The main agent analyzes the PR holistically before launching subagents. This analysis is included in the unified report and provided to each subagent.

**Analyze** PR title/body, commit history, changed files, and diff to produce:

1. **修正の目的** — この PR が解決する課題・要件（1-3文）
2. **アプローチ** — 技術的アプローチ（箇条書き）
3. **設計・アーキテクチャ判断** — 新規パターン導入、レイヤー構成変更、データフロー変更（該当する場合のみ）

   **Backend project の場合は以下も分析する:**
   - トランザクション境界の設計（startTx の粒度、ネストの有無）
   - CQRS 境界の保持（Command/Query の分離）
   - テナント分離の取り扱い（organizationId のフロー）

4. **影響範囲** — 影響するモジュール・機能、リグレッションリスク
5. **人間レビュー観点** — AI では判断しきれないポイント:
   - **設計判断**: 選択されたアプローチの妥当性、代替案の有無
   - **仕様整合性**: ビジネスロジック・仕様要件との整合
   - **アーキテクチャ統一性**: 既存パターンとの一貫性
   - **命名・責務分離**: 命名の適切さ、責務の明確さ
   - **パフォーマンス影響**: 大量データ・高頻度呼び出しでの懸念

   **Backend project の場合は以下も分析する:**
   - **テナント分離**: organizationId フィルタの適用漏れリスク
   - **トランザクション境界**: startTx の粒度、ネストトランザクションの有無

### Phase 3: Select & Execute Agents

#### 1. Determine diff scale

| Scale | Condition | Max agents |
|-------|-----------|-----------|
| Small | < 100 lines changed | 2 |
| Medium | 100-500 lines changed | Standard selection |
| Large | > 500 lines changed | All applicable |

#### 2. Select agents by project type and changed files

**Frontend project** (`project_type = frontend`):

| Agent | Condition | Rules to provide |
|-------|-----------|-----------------|
| pm-reviewer | UI/API/ビジネスロジックの変更を含む場合 | — |
| code-quality-reviewer | ソースコード（.ts/.tsx）の変更を含む場合 | `coding-rule.mdc`, `project-structure.mdc` |
| frontend-reviewer | フロントエンドファイルの変更を含む場合 | `coding-rule.mdc`, `project-structure.mdc`, `typography.mdc`, `icon.mdc`, `deprecated-shadcn.mdc`, `data-table-impl.mdc`, `crud-patterns-impl.mdc` |
| infrastructure-reviewer | インフラファイルの変更を含む場合 | — |

**Backend project** (`project_type = backend`):

| Agent | Condition | Rules to provide |
|-------|-----------|-----------------|
| pm-reviewer | API/ビジネスロジックの変更を含む場合 | — |
| backend-reviewer | ソースコード（.ts）の変更を含む場合 | `architecture.mdc` 要約, `coding-rule.mdc` 要約, backend checklist（後述） |
| database-reviewer | Prisma スキーマ・マイグレーション・QueryService・Repository の変更、または .prisma ファイルの変更を含む場合 | `coding-rule.mdc`（DB 関連セクション）, database checklist（後述） |
| infrastructure-reviewer | Dockerfile, docker-compose, CI, AWS 設定の変更を含む場合 | — |

**Unknown project** (`project_type = unknown`): 従来通り、変更ファイルの種類に基づいて全エージェントから選択する。

Small scale の場合、最も関連性の高い2エージェントのみ起動する。

#### Backend-reviewer additional instructions (backend project only)

backend-reviewer に以下のチェックリストをインライン指示として渡す。
これらは CI では検出困難な設計レベルの問題である。
`architecture.mdc` と `coding-rule.mdc` は全文ではなく要約を渡すこと。

##### 必須チェック（全 diff サイズで適用）

**クロステナントセキュリティ**:
- テーブルアクセス時の organizationId フィルタ漏れ
- organizationId が Infrastructure 層で ApiContext から付与されているか
- JOIN/サブクエリの結合先にもフィルタが適用されているか

**エラーハンドリング設計**:
- 例外 throw 禁止、neverthrow の Result 型使用
- ErrorWithDisplayMessages 拡張クラスの 6 言語対応（en, ja, id, vn, th, zhCN）
- Command の of() ファクトリで入力値を検証し Result 型で返しているか

**Prisma / DB 制約**:
- 新規コードで OrThrow 系関数不使用（findFirstOrThrow, findUniqueOrThrow 等）
- DTO Optional 項目が null（undefined ではなく）
- any 型不使用

##### 推奨チェック（Medium / Large diff で追加適用）

**アーキテクチャ整合性**:
- Domain → Infrastructure 依存がないか
- 別モジュールの内部実装を直接参照していないか（Adapter 経由か）
- Command → Query の依存がないか
- DTO/VO にビジネスロジックが混入していないか

**CQRS パターン検証**:
- Command Handler が 1 責務か
- Handler が tx: PrismaTx を引数で受け取っているか
- ビジネスルールが Entity に委譲され、Handler はオーケストレーションのみか

**Prisma / DB 制約（追加）**:
- 新規 View テーブル追加なし、View リレーションなし
- 新規テーブルの日付カラムに @db.Date
- exhaustive check で全エラーケースを処理

**Temporal データ整合性**（該当する場合のみ）:
- whereBi/whereUni フィルタの適用
- include 内での Temporal フィルタ適用
- setReadCursor / resetReadCursor の try/finally ペア

#### Database-reviewer additional instructions (backend project only)

**Prisma 固有チェック**:
- View テーブル新規追加・リレーション禁止（Prisma 6.13.0 以降非対応）
- Kysely の使用回避（メンテナンス性・可読性の観点）
- マイグレーションの安全性（既存データへの影響、ダウンタイム有無）
- 新規クエリに対応するインデックス設計
- JSON 型定義の整合性（prismaJson.d.ts との一致）

#### 3. Launch all selected subagents in parallel

Provide each subagent with:
- PR number, title, base branch
- Phase 2 の PR 概要分析（目的・アプローチ・設計判断）
- Full diff and changed file list
- Subagent Output Template
- Relevant `.cursor/rules/` content
- **CI exclusion rule**: 「CI で検出される問題（型エラー、lint 違反、テスト失敗）は指摘対象外」
- (backend project) Backend/Database checklist from above

Confirm every selected subagent has started. Re-launch any that failed.

### Phase 4: Aggregate & Report

#### 1. Collect & deduplicate

- Read each `./tmp/review/{agent}-review.md`
- Merge identical issues into one finding, listing all agreeing agents: `[frontend・code-quality]`
- Use **カテゴリタグ** for mechanical matching during deduplication
- **Low confidence の指摘は ℹ️ Info 以下に自動降格**

#### 2. Generate unified report

```bash
mkdir -p ./tmp/review
```

Write `./tmp/review/unified.md`:

```markdown
# コードレビューレポート

**PR #{number}**: {title}
**ブランチ**: `{head}` → `{base}`
**レビュー日**: {date}
**変更ファイル数**: {count}ファイル | **差分規模**: {small/medium/large}
**プロジェクトタイプ**: {frontend/backend/unknown}

---

## ❌ CI Failures（最優先）

> Phase 1.6 で `tmp/review/_ci-failures.md` が生成されている場合のみ表示する。CI 失敗が無い場合は本セクション全体を省略する。

| Check | Bucket | Link |
|-------|--------|------|
| {check name} | fail | {link} |

### {check name} の失敗詳細

```
{tail -n 30 of failed log}
```

---

## CI 前提確認

> 以下は CI で自動検出されるため、本レビューではチェック対象外:
> - 型エラー（typecheck）
> - コーディング規約違反（lint）
> - テスト失敗（test）
>
> 本レビューは CI では検出困難な設計・アーキテクチャ・セキュリティ観点に集中する。

---

## 変更サマリ

### 修正の目的

{この PR が解決する課題・要件（1-3文）}

### アプローチ

- {主要な変更1}
- {主要な変更2}
- ...

### 設計・アーキテクチャ判断

{該当しない場合は「特になし」}

### 影響範囲

{変更が影響するモジュール・機能。リグレッションリスクがあれば記載}

---

## 👀 人間レビュー観点（Human Review Points）

> AI だけでは判断しきれない、人間の確認が必要なポイント。
> 該当なしのカテゴリは省略。各項目に判断材料となる具体的コンテキストを記載。

### 設計判断

- **H-1. {タイトル}** — `src/path/to/file.tsx:L42`
  {なぜこのアプローチが選ばれたか。代替案があれば記載}

### 仕様整合性

- **H-2. {タイトル}** — `src/path/to/file.tsx:L100`
  {仕様要件との整合が必要な箇所}

### アーキテクチャ統一性

- **H-3. {タイトル}** — `src/path/to/file.tsx (ComponentName)`
  {既存パターンとの一貫性}

### 命名・責務

- **H-4. {タイトル}** — `src/path/to/file.tsx:L20`
  {命名の適切さ、責務の分離}

### その他

- **H-5. {タイトル}** — `src/path/to/file.tsx:L80`
  {パフォーマンス、セキュリティ、拡張性}

---

## ❌ Critical Issues（修正必須）

### C-1. {問題タイトル}
**エージェント**: {指摘元} | **確信度**: High | **カテゴリ**: {tag}
**ファイル**: `src/full/path/to/file.tsx:L42-50`

{詳細説明}

```tsx
// ❌ 現状
<problematic code>

// ✅ 修正案
<fixed code>
```

---

## ⚠️ Minor Issues（改善提案）

### M-1. {問題タイトル}
**エージェント**: {指摘元} | **確信度**: {level} | **カテゴリ**: {tag}
**ファイル**: `src/full/path/to/file.tsx:L15`

{詳細説明}

---

## ℹ️ Info & Questions（確認事項）

### I-1. {タイトル}
**ファイル**: `src/full/path/to/file.tsx:L100`

{詳細説明}

---

## ✅ Good Points（良い実装）

1. **{タイトル}** — {説明} [{エージェント名}]

---

## 📊 サマリー

| 区分 | 件数 |
|------|------|
| ❌ Critical | X件 |
| ⚠️ Minor | Y件 |
| ℹ️ Info | Z件 |
| ✅ Good | W件 |

### 優先対応（Critical がある場合のみ表示）

1. **C-1** `src/path/file.tsx:L42` — {概要}

---

*レビュー by {参加エージェント名一覧}（並列実行）*
```

#### 3. Console output

Provide the following to the user:

1. **変更サマリ** — 修正の目的（1-2文）、アプローチ要点（2-3項目）、設計判断（該当時のみ）
2. **👀 人間レビュー観点** — 最重要項目を最大5件（ファイルパス + 確認理由）
3. **指摘サマリ** — Critical / Minor / Info 件数、優先対応項目
4. **出力ファイル** — `./tmp/review/unified.md` and `./tmp/review/*-review.md`
