---
name: review
description: PR / 変更差分を専門サブエージェント並列でレビューする。実装完了後の品質確認、`/implement` の後、PR 作成前、`/review` 呼び出しで使用。
---

Perform comprehensive code review using specialized AI agents working in parallel.

**IMPORTANT**: Never modify source files — only output review files.
**規約**: CLAUDE.md の Skills 共通規約に従う

## 補助ドキュメントへの参照

| 補助ドキュメント | 読むタイミング |
|------------------|----------------|
| `./reference/edge-case-reverification.md` | Critical Issue が出た時 / 境界値・並行処理・テナント分離・トランザクション境界を含む変更の時 / 既存テストカバレッジが低い領域を変更した時 |

「念のため全部読む」は禁止。表のトリガー条件に該当する場合のみ読み込む。
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

### Phase 2.5: Snapshot Shared Context

並列起動するサブエージェントに同じ context を inline で配信すると重複コストが大きい（agent 数 × 数百トークン）。共有コンテキストをスナップショットとして保存し、サブエージェントには **「これらを読め」** とパス参照のみを渡す方式に切り替える。

```bash
mkdir -p tmp/review

# PR 差分とコミット履歴のスナップショット
echo "$full_diff" > tmp/review/_pr-diff.snapshot
echo "$commit_log" > tmp/review/_commits.snapshot

# Phase 2 の分析結果（修正の目的 / アプローチ / 設計判断 / 影響範囲 / 人間レビュー観点）
cat > tmp/review/_overview.md <<'EOF'
# PR Overview

## 修正の目的
...

## アプローチ
...

## 設計・アーキテクチャ判断
...

## 影響範囲
...

## 人間レビュー観点
...
EOF
```

Phase 3 で各サブエージェントには以下のみを渡す:
- PR メタデータ（番号、ベースブランチ、変更ファイル数）
- スナップショットファイルのパス（`tmp/review/_pr-diff.snapshot`, `tmp/review/_overview.md`）
- 観点別チェックリスト（agent 固有）
- 出力テンプレート

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

#### Backend / Database checklist (backend project only)

backend-reviewer / database-reviewer 起動時に渡すチェックリスト（必須 + 推奨 + Prisma 固有）は **`./reference/backend-checklist.md`** を参照。inline 指示として渡せる形式で記載されている。

#### 3. Launch all selected subagents in parallel

各サブエージェントには **スナップショット参照のみ** を渡す（Phase 2.5 で生成済み）:

- PR メタデータ（number, title, base branch、変更ファイル数のみ）
- **スナップショットパス**:
  - `tmp/review/_pr-diff.snapshot` を読んで full diff を把握する旨
  - `tmp/review/_commits.snapshot` を読んでコミット履歴を把握する旨
  - `tmp/review/_overview.md` を読んで Phase 2 の分析結果（目的・アプローチ・設計判断・影響範囲・人間レビュー観点）を把握する旨
- Subagent Output Template
- Relevant `.cursor/rules/` content（agent ごとに異なるため inline は維持）
- **CI exclusion rule**: 「CI で検出される問題（型エラー、lint 違反、テスト失敗）は指摘対象外」
- (backend project) Backend/Database checklist from above

> **NOTE**: full diff、commit log、PR overview を prompt に inline すると agent 数 × 数百トークンの重複コストになるため、必ずスナップショット参照に統一する。

Confirm every selected subagent has started. Re-launch any that failed.

### Phase 4: Aggregate & Report

#### 1. Collect & deduplicate

- Read each `./tmp/review/{agent}-review.md`
- Merge identical issues into one finding, listing all agreeing agents: `[frontend・code-quality]`
- Use **カテゴリタグ** for mechanical matching during deduplication
- **Low confidence の指摘は ℹ️ Info 以下に自動降格**

#### 2. Generate unified report

`mkdir -p ./tmp/review` してから、**`./reference/unified-report-template.md`** に記載されたテンプレートに従って `./tmp/review/unified.md` を生成する。

テンプレートには以下のセクションが含まれる（順序固定）:
- ヘッダ（PR 番号 / ブランチ / レビュー日 / 差分規模 / プロジェクトタイプ）
- ❌ CI Failures（Phase 1.6 で `_ci-failures.md` が生成された場合のみ）
- CI 前提確認 / 変更サマリ / 👀 人間レビュー観点
- ❌ Critical Issues / ⚠️ Minor Issues / ℹ️ Info / ✅ Good Points
- 📊 サマリー + 優先対応（Critical がある場合のみ）

各 Issue は **エージェント名 / 確信度 / カテゴリ / ファイルパス + 行番号 / 詳細 / 修正案コード** を含むこと。

#### 3. Console output

Provide the following to the user:

1. **変更サマリ** — 修正の目的（1-2文）、アプローチ要点（2-3項目）、設計判断（該当時のみ）
2. **👀 人間レビュー観点** — 最重要項目を最大5件（ファイルパス + 確認理由）
3. **指摘サマリ** — Critical / Minor / Info 件数、優先対応項目
4. **出力ファイル** — `./tmp/review/unified.md` and `./tmp/review/*-review.md`

#### HTML view 化 (オプション)

unified.md 生成完了直後に、以下をユーザーに尋ねる (Phase 4 末尾固定。Phase 5 で再実行しない):

> **HTML 化しますか?** (人間レビュア向けのデザイン HTML を生成)

ユーザーが Yes と回答した場合、**Claude は自動実行せず**、次のコマンドを案内する:

```
/html-view ./tmp/review/unified.md
```

ユーザーが明示的に slash command を入力することで HTML 生成 + ブラウザ自動起動が完了する。

### Phase 5 (任意): Edge Case 再検証（subagent 並列）

Phase 4 の集約結果が以下のいずれかに該当する場合、追加の subagent 並列レビューで edge case を再検証する:

- **Critical Issue が 1 件以上検出された**
- 変更が **境界値処理 / エラーハンドリング / 非同期処理 / 並行処理** を含む
- 変更が **テナント分離 / 認可 / トランザクション境界** を含む
- 既存テストカバレッジが低い領域（テストなしファイルの変更）

詳細手順とカテゴリ別 subagent 指示テンプレートは `./reference/edge-case-reverification.md` を参照。

実行時の注意:

- **同じ turn で複数 Agent 呼出を発行する**（並列実行）。直列で 1 つずつ呼んではいけない
- カテゴリは 2-4 個に絞る（全部やると冗長）。変更内容に応じて選択
- 結果は `tmp/review/_edge-{category}-review.md` に出力し、Phase 4 の unified.md に統合する

該当しない場合（純粋な UI スタイル変更 / ドキュメントのみ / リネームのみ）は本 Phase をスキップしてよい。
