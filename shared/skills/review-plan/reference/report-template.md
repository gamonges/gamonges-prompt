# plan-review.md レポートテンプレート

`/review-plan` フェーズ 4 で `./tmp/plan-review.md` を出力する際の構成。該当なしの区分はセクションごと省略する。

`**Codex レビュー**:` 行は `**総合判定**:` 行の後ろに置き、`**総合判定**:` 行は変えない（`plan-lgtm` がこの行を文字列一致で読む）。`**出所**:` 行は Codex の指摘を写した Critical・Warning・Note のどれにも付ける（書き方は `../../review/reference/codex-reviewer.md` の「写し方」）。

<!-- tmp-frontmatter: tmp/plan-review.md -->
```markdown
---
type: Plan Review
title: {計画の題材} のレビュー
description: {総合判定と主な指摘を 1 文}
status: stable
---
# 実装計画レビュー

**対象**: {計画ファイルパス}
**レビュー日**: {date}
**総合判定**: {LGTM / 要修正 / 要再設計}
**Codex レビュー**: {実施（gpt-6.1-sol、52 秒、指摘 1 件） / 未実施（理由） / 省略（実行者が Codex） / 省略（--no-codex）}

---

## 計画の概要

{レビュー対象の計画を簡潔に要約（2-3行）}

---

## ❌ Critical（修正必須）

### C-1. {問題タイトル}
**参照**: `plan.md:L{number}`
**出所**: {Codex（gpt-6.1-sol） / Claude と Codex の両方}（Claude だけの指摘では行ごと省く）

{詳細説明: 何が問題で、なぜ修正が必要か}

**推奨対応**:
{具体的な修正方法}

---

## ⚠️ Warning（修正推奨）

### W-1. {問題タイトル}
**参照**: `plan.md:L{number}`
**出所**: {Codex（gpt-6.1-sol） / Claude と Codex の両方}（Claude だけの指摘では行ごと省く）

{詳細説明}

**推奨対応**:
{具体的な修正方法}

---

## ℹ️ Note（検討推奨）

### N-1. {タイトル}
**参照**: `plan.md:L{number}`
**出所**: {Codex（gpt-6.1-sol） / Claude と Codex の両方}（Claude だけの指摘では行ごと省く）

{詳細説明}

---

## 💡 代替アプローチ

### A-1. {提案タイトル}
**関連**: `plan.md:L{number}`

{代替案の説明とトレードオフ}

---

## ✅ Good Points（計画の良い点）

1. **{タイトル}** — {説明}
2. ...

---

## 📊 サマリー

| 区分 | 件数 |
|------|------|
| ❌ Critical | X件 |
| ⚠️ Warning | Y件 |
| ℹ️ Note | Z件 |
| 💡 代替案 | W件 |
| ✅ Good | V件 |

---

## /revise への入力ガイド

以下の指摘を `/revise` に渡して計画を修正してください:

### 修正必須（Critical）
- C-1: {概要と修正方針}
- C-2: ...

### 修正推奨（Warning）
- W-1: {概要と修正方針}
- W-2: ...

実行コマンド:
\```
/revise ./tmp/plan-review.md
\```
```
