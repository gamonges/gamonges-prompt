---
description: AI code review using specialized subagents (/review)
---

Perform comprehensive code review using specialized AI agents working in parallel.

**IMPORTANT**: Never modify source files — only output review files.
**IMPORTANT**: Always respond in Japanese.

## Execution Conditions

You must verify the following conditions before proceeding:

- Pull Request exists for the current branch (draft or opened), OR
  the user appended a Pull Request link or number after the command.

If any condition is not met:

- Stop the process immediately
- Notify the user which condition failed
- Do not proceed

## Finding Format Standard

**All agents MUST use this format for every finding:**

```
- `src/path/to/file.tsx:L42` — 指摘内容
```

Rules:

- File paths MUST be **relative from project root** (e.g. `src/apps/app/src/routes/_staff/...`)
- Line numbers use `L{number}` format (single line) or `L42-50` (range)
- If the exact line cannot be determined, append the symbol name: `src/path/file.tsx (ComponentName)`
- **NEVER use bare file names** like `DetailHeader.tsx` — always include the full relative path

## Subagent Output Template

Each subagent MUST write its review to `./tmp/{agent-name}-review.md` using this structure:

```markdown
# {Agent Name} Review — PR #{number}

## レビュー結果

### ❌ Critical Issues

1. **問題タイトル**
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

## Specialized Review Agents

The review system employs domain-specific agents selected per Phase 3:

1. **Product Manager** — Requirements alignment, acceptance criteria, UX consistency
2. **Backend Developer** — Server-side architecture, APIs, data integrity
3. **Frontend Developer** — UI components, state management, performance, React hooks, TanStack Router/Query patterns
4. **UI Engineer** — Web standards, accessibility, design-system compliance
5. **Infrastructure Engineer** — AWS, Terraform, CI/CD
6. **Database Engineer** — MySQL, PostgreSQL, ORMs, migrations
7. **Quality Engineer** — Testing, reliability, maintainability, edge cases
8. **Refactoring Expert** — Code quality, naming, design principles, DRY

Additionally, when frontend files are changed, the built-in **code-reviewer** subagent is invoked via `Task(subagent_type="code-reviewer")` to catch bugs, logic errors, and security issues with high confidence.

## Frontend-Specific Review Criteria

When frontend files are changed, the Frontend Developer agent and code-reviewer MUST check:

### React Hooks

- `useCallback` / `useMemo` dependency arrays: no unstable references (e.g. whole mutation object instead of `.mutate`)
- Custom hook responsibilities are clear (UI logic vs data logic)
- No unnecessary re-renders from inline objects/functions in JSX

### TanStack Query

- `staleTime` and `refetchOnWindowFocus` are configured
- Query Key Factory pattern is used (`-query/key.ts`)
- Data transformation is in `selector.ts`, not inline
- Mutation `onSuccess` invalidates relevant query cache

### TanStack Router

- `validateSearch` uses a Zod schema
- Loader return types are correct (avoid `as` type assertions)
- Route-specific components live in `-components/`

### Design System Compliance

- `Text` component or `cn('text-variant')` for typography (per `typography.mdc`)
- `Icon` component for all icons (per `icon.mdc`)
- No shadcn-banned CSS classes (per `deprecated-shadcn.mdc`)
- Design-system `Button`, `Input`, etc. instead of native HTML elements

### Project Architecture

- `-query/` directory structure: `api.ts`, `index.ts`, `key.ts`, `selector.ts`, `type.ts`
- 3-layer pattern: Query Layer → Hook Layer → Component Layer
- No `any` types; strict TypeScript

## Execution Process

### Phase 1: Verify Pull Request & Collect Metadata

```bash
current_branch=$(git branch --show-current)

pr_number=$(gh pr list --head "$current_branch" --state all --json number --jq '.[0].number')

if [ "$pr_number" = "null" ] || [ -z "$pr_number" ]; then
    echo "No PR found for branch: $current_branch"
    exit 1
fi

base_branch=$(gh pr view "$pr_number" --json baseRefName --jq '.baseRefName')
pr_title=$(gh pr view "$pr_number" --json title --jq '.title')
```

### Phase 2: Collect Diff

```bash
changed_files=$(git diff --name-only "${base_branch}...HEAD")
full_diff=$(git diff "${base_branch}...HEAD")
```

### Phase 3: Select Agents

1. **Analyze Changed Files**
   - Examine file extensions, paths, and directory structure
   - Review diff content to understand the nature of changes

2. **Select Required Agents**

   | Agent | Condition | Rules to provide |
   |-------|-----------|-----------------|
   | pm-reviewer | Always | — |
   | qa-reviewer | Always | `coding-rule.mdc` |
   | refactoring-reviewer | Always | `coding-rule.mdc`, `project-structure.mdc` |
   | frontend-reviewer | Frontend files changed | `coding-rule.mdc`, `project-structure.mdc`, `typography.mdc`, `icon.mdc`, `deprecated-shadcn.mdc`, `data-table-impl.mdc`, `crud-patterns-impl.mdc` |
   | ui-reviewer | Frontend files changed | `typography.mdc`, `icon.mdc`, `deprecated-shadcn.mdc` |
   | **code-reviewer** (built-in) | Frontend files changed | (provided via Task prompt) |
   | backend-reviewer | Backend files changed | — |
   | database-reviewer | Database/migration files changed | — |
   | infrastructure-reviewer | Infrastructure files changed | — |

### Phase 4: Parallel Agent Execution

1. **Launch all selected subagents in parallel**

   Provide each subagent with:
   - PR number, title, base branch
   - Full diff and changed file list
   - The **Finding Format Standard** (above)
   - The **Subagent Output Template** (above)
   - Relevant `.cursor/rules/` content for its domain

   For the **code-reviewer**, use the built-in subagent:

   ```
   Task(
     subagent_type = "code-reviewer",
     prompt = "<PR diff and context> Review for bugs, logic errors, security vulnerabilities, and code quality."
   )
   ```

2. **Verify execution**

   Confirm every selected subagent has started. Re-launch any that failed to start.

### Phase 5: Result Aggregation

1. **Collect Agent Outputs**
   - Wait for all subagents to complete
   - Read each `./tmp/{agent}-review.md` for custom agents
   - For the built-in **code-reviewer**, capture its Task response directly (it does not write to a file)

2. **Deduplicate Findings**
   - Merge identical issues reported by multiple agents into one finding
   - List all agreeing agents: `[Frontend・Refactoring]`

3. **Categorize by Severity** (preserving full file paths and line numbers)
   - ❌ Critical Issues: Must-fix before merge
   - ⚠️ Minor Issues: Non-critical improvements
   - ℹ️ Info & Questions: Clarifications needed

4. **Collect Good Points**
   - Gather ✅ Good Points from all subagents
   - Deduplicate and attribute

### Phase 6: Generate Unified Report

Write `./tmp/review.md` using the following template:

```markdown
# コードレビューレポート

**PR #{number}**: {title}
**ブランチ**: `{head}` → `{base}`
**レビュー日**: {date}
**変更ファイル数**: {count}ファイル

---

## PR 概要

{PR の目的と主な変更点を簡潔に記述}

---

## ❌ Critical Issues（修正必須）

### C-1. {問題タイトル}
**エージェント**: {指摘元エージェント名}
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
**エージェント**: {指摘元エージェント名}
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
2. ...

---

## 📊 サマリー

| 区分 | 件数 |
|------|------|
| ❌ Critical | X件 |
| ⚠️ Minor | Y件 |
| ℹ️ Info | Z件 |
| ✅ Good | W件 |

### 優先対応（マージ前に修正推奨）

1. **C-1** `src/path/file.tsx:L42` — {概要}
2. **C-2** `src/path/file.tsx:L100` — {概要}
...

---

*レビュー by {参加エージェント名一覧}（並列実行）*
```

### Phase 7: Completion Report

Provide summary to user:

- Number of Critical / Minor / Info findings
- Top priority items to fix next
- List of output files (`./tmp/review.md` and individual `./tmp/*-review.md`)
