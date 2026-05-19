# 修正項目の収集・分類

> SKILL.md フェーズ 1 で「修正項目を読み込み・分類する」と書かれている部分の詳細。
> PR レビューコメント取得の GraphQL、bot フィルタ、種別分類を含む。

## `./tmp/fixes.md` の推奨フォーマット

ユーザーはレビュー中に以下のフォーマットで修正項目を記録する（自由形式も受け付ける）:

```markdown
# 修正項目

## 修正 1: [修正タイトル]
- **ファイル**: `src/path/to/file.ts:L42`
- **問題**: [何が問題か]
- **期待する動作**: [どうあるべきか]

## 修正 2: [修正タイトル]
...
```

区切り文字 `=====` による列挙形式も許容する。

## `$ARGUMENTS` の種別判定

| パターン | 種別 | 例 |
|----------|------|-----|
| `https://github.com/...` を含む | PR URL | `https://github.com/org/repo/pull/123` |
| 数字のみ | PR 番号 | `123` |
| 上記以外 | ファイルパス | `./tmp/fixes.md` |
| 未指定 | デフォルト | `./tmp/fixes.md` を使用 |

## PR レビューコメントの取得

`$ARGUMENTS` が PR URL/番号の場合、PR 上の未解決レビューコメントを取得して修正項目に含める。

### PR 基本情報

```bash
pr_url="$ARGUMENTS"
gh pr view "$pr_url" --json number,title,baseRefName,headRefName,author,state
```

### 未解決レビュースレッドの GraphQL クエリ

```bash
gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        nodes {
          isResolved
          isOutdated
          path
          line
          startLine
          comments(first: 50) {
            nodes {
              author { login }
              body
              createdAt
              url
              originalPosition
              diffHunk
            }
          }
        }
      }
    }
  }
}' -f owner="$owner" -f repo="$repo" -F number="$number"
```

### フィルタリングルール

1. **resolved 済みを除外**: `isResolved: true` のスレッドはスキップ
2. **bot コメントを除外**: 以下に該当する作成者はスキップ
   - `[bot]` を含むユーザー名（`github-actions[bot]`, `dependabot[bot]` 等）
   - `copilot`, `gemini`, `coderabbit` など既知の AI レビュー bot
3. **outdated スレッドの扱い**: 取得するが outdated である旨を明記

取得した各コメントを修正項目として統合する。`path` と `line` をファイル参照、`body` を問題説明として扱う。

## 現在の実装状態の把握

```bash
git diff HEAD --stat
git log --oneline -10
```

`./tmp/plan.md` が存在する場合、元の計画との差分を分析する（計画にあるが実装されていない項目を特定）。

## 修正項目の統合と分類

収集した入力から修正項目を統合する:

- `./tmp/fixes.md` の明示的な修正指示（存在する場合）
- PR 上の未解決レビューコメント（PR URL/番号が指定された場合）
- `./tmp/review/unified.md` の ❌ Critical Issues と ⚠️ Minor Issues（存在する場合）
- `./tmp/plan.md` との比較で特定した未実装・実装漏れ項目（存在する場合）

### 種別分類

| 種別 | 説明 |
|------|------|
| **バグ修正** | 動作が仕様・意図と異なる誤りの修正 |
| **実装漏れ** | plan.md に定義されたが実装されなかった項目 |
| **品質改善** | コード品質・可読性・型安全性の向上 |
| **テスト追加** | カバレッジ不足や漏れたエッジケースへの対応 |

重複項目は統合し、出典を記録する（例: `[fixes.md + review.md]`）。

## 優先度の決定

- **P1 (Critical)**: 動作バグ・データ不整合・セキュリティ問題
- **P2 (High)**: 実装漏れ・型安全性の違反
- **P3 (Medium)**: 品質改善・リファクタリング
- **P4 (Low)**: コメント整理・スタイル調整

## ユーザー確認が必要な状況

以下を検出した場合は**プロセスを即座に停止**してユーザーに報告:

- **修正意図が不明**: 「何をどう直すか」が複数解釈可能
- **修正間の矛盾**: 複数の修正項目が互いに矛盾
- **影響範囲が不明確**: 他コンポーネントへ大きく波及する可能性

```
## 問題 1: [問題の要約]
[該当する修正項目の引用と、何が問題なのかの説明]

## 問題 2: [問題の要約]
...
```
