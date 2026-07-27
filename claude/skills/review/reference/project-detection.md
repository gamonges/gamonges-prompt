# Project Type Detection

`/review` Phase 1.5 でプロジェクト種別を判定する手順。結果の `project_type` は Phase 3 のエージェント選択に使う。

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
