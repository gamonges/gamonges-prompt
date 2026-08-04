---
name: stack-pr-init
description: 新規スタック PR を開始する。gh-stack 拡張の前提条件チェック（自動インストール含む）の SSOT。「スタック PR 開始」「新規スタック」`/stack-pr-init` で使用
---

現在の作業を新規のスタック PR として開始する。GitHub 公式拡張 `gh-stack` の薄いラッパーとして `gh stack init` を実行する。

## 前提条件チェック（SSOT）

他の `stack-pr-*` skill も本チェックを行うが、記述の正本は本 skill とする（詳細は `../stack-pr-init/SKILL.md` を参照、と 1 行で引用し再宣言しない）。以下をすべて確認する（他 stack-pr-* skill から共通参照される）。いずれか未達の場合は処理を即座に停止し、どの条件が満たされていないかをユーザーに報告する。

### ブランチ・fork・gh CLI の確認

```bash
current_branch=$(git branch --show-current)
base_branch=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
is_fork=$(gh repo view --json isFork -q .isFork)
gh_major=$(gh --version | head -1 | grep -oE '[0-9]+' | head -1)

if [ "$current_branch" = "$base_branch" ]; then
    echo "Error: 既定ブランチ ($base_branch) 上ではスタックを開始できません"
    exit 1
fi
if [ "$is_fork" = "true" ]; then
    echo "Error: このリポジトリは fork です。gh-stack はクロスフォークのスタックに対応していません"
    exit 1
fi
if [ "$gh_major" -lt 2 ]; then
    echo "Error: gh CLI 2.0 以上が必要です（現在: $(gh --version | head -1)）"
    exit 1
fi
gh auth status || { echo "Error: gh 未認証です。gh auth login を実行してください"; exit 1; }
```

### gh-stack 拡張の有無確認

```bash
if ! gh extension list | grep -q "github/gh-stack"; then
  echo "gh-stack 拡張が未インストールのため自動インストールします: gh extension install github/gh-stack"
  gh extension install github/gh-stack
fi
```

無言実行はせず、インストール実行前に必ずその旨を表示する（透明性確保）。実行後の確認・停止は不要 — ユーザーはこの自動インストール方針を既に承認済み。

### スタック未初期化時の案内（SSOT）

`gh stack view` 等が「スタック未初期化」を示すエラーを返した場合、「まず `/stack-pr-init` でスタックを開始してください」と案内する。

## 実行プロセス

1. 上記チェックを実行する
2. 新規スタックの最初のレイヤーとなるブランチ名をユーザーに確認する（既に作業ブランチが存在する場合はそのブランチ名を提示し採用可否を確認する）
3. `gh stack init <branch-name>` を実行する。ユーザーが別の trunk を指定した場合のみ `--base <branch>` を付与する
4. 完了報告: スタックが開始されたこと、次のアクション（`/stack-pr-add` でレイヤー追加、`/stack-pr-submit` で PR 化）を案内する
