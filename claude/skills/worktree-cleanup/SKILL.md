---
name: worktree-cleanup
description: マージ済み PR の worktree を一括削除する。「worktree を掃除」「worktree cleanup」「マージ済み worktree を削除」等のキーワードで呼び出す。`claude -w` で作った worktree が溜まったときの定期整理に使用。
---

# Worktree Cleanup Skill

`claude -w` で作成したworktreeを、PRマージ後にまとめて削除するためのスキル。

## 同梱 scripts

| script | 用途 |
|--------|------|
| `./scripts/list-merged.sh` | マージ済 PR と対応 worktree を 1 コマンドで列挙する。Step 1-3 の手順を最小実装で取得したい時に使う |

実行例:

```bash
./scripts/list-merged.sh
```

`gh` 認証が必須。詳細な判定（未コミット変更チェック等）は本 SKILL の手順を参照。

## 概要フロー

1. **前処理** — リモート同期と無効参照の掃除
2. **一覧取得** — 現在のworktreeとチェックアウト中ブランチを列挙
3. **マージ済み判定 + 状態チェック** — マージ状態と未コミット変更を確認
4. **確認フェーズ** — 削除候補をユーザーに提示して確認を取る
5. **削除実行** — 承認されたworktreeのみ削除（claude-context MCP 接続時は対応するインデックスも削除）

---

## Step 1: 前処理

すべての判定の前に、リモートの最新状態を取得し、無効な worktree 参照を掃除する。

```bash
# リモートの最新状態を取得（削除済みリモートブランチの参照も除去）
git fetch origin --prune

# パスが消失した無効な worktree 参照を掃除
git worktree prune
```

これにより:
- Step 3 の gh CLI / git 両パスでリモートの最新状態が保証される
- 既にディスクから消えているが Git の内部参照だけ残っている worktree が除去される

---

## Step 2: worktree一覧の取得

```bash
git worktree list --porcelain
```

出力例（実際のパスは環境・設定によって異なる）：
```
worktree /path/to/repo
HEAD abc1234
branch refs/heads/main

worktree /path/to/repo/.worktrees/feature-foo
HEAD def5678
branch refs/heads/feature/foo

worktree /path/to/repo/.worktrees/fix-bar
HEAD 9ab0123
branch refs/heads/fix/bar
```

- 最初のエントリ（メインのworktree）は**絶対にスキップ**する
- `branch` が `detached` の場合もスキップ（削除判断が難しいため、ユーザーに別途確認）
- Step 1 で prune 済みのため、一覧には有効な worktree のみが含まれる

---

## Step 3: マージ済み判定 + 状態チェック

各worktreeのブランチについて、マージ状態と未コミット変更を確認する。

### 3-1. マージ済み判定

#### gh CLIが使える場合（推奨・より正確）

```bash
# ブランチ名からPRのマージ状態を確認
gh pr list --head <branch-name> --state merged --json number,title,mergedAt
```

- 結果が空でなければ「マージ済み」と判定
- 同一ブランチで複数のマージ済み PR が返された場合は、`mergedAt` が最新の PR を採用する
- **結果が空の場合**、リモートにブランチが存在するか確認する:
  ```bash
  git ls-remote --heads origin <branch-name>
  ```
  - リモートにも存在しない:
    - ブランチ名が `review-*` パターンに一致 → 削除候補に追加（`claude -w` が作成した一時ブランチと判断）
    - それ以外 → スキップ、ユーザーに通知（push 前のローカルブランチの可能性）
  - リモートに存在するが PR なし → 未マージとして扱う

#### gh CLIが使えない場合（fallback）

```bash
# Step 1 の fetch で更新済みのローカル参照を使用（ネットワーク不要）
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@refs/remotes/origin/@@')
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}

git branch -r --merged origin/$DEFAULT_BRANCH | grep "origin/<branch-name>"

# develop ブランチが存在する場合のみチェック
if git rev-parse --verify origin/develop &>/dev/null; then
  git branch -r --merged origin/develop | grep "origin/<branch-name>"
fi
```

- どちらかにマージされていれば「マージ済み」と判定
- リモートにブランチが存在しない場合:
  - ブランチ名が `review-*` パターンに一致 → 削除候補に追加
  - それ以外 → スキップしてユーザーに知らせる

### 3-2. 未コミット変更チェック

マージ済みと判定されたworktreeに対して、未コミットの変更がないか確認する。

```bash
git -C /path/to/worktree status --porcelain
```

- 出力が空 → 変更なし
- 出力がある → 未コミット変更あり（Step 4 の確認フェーズで ⚠️ 警告として表示する）

### 3-3. 判定結果の分類

| 状態 | 対応 |
|------|------|
| マージ済み（変更なし） | 削除候補に追加 |
| マージ済み + 未コミット変更あり | 削除候補に追加（⚠️ 警告付き） |
| 未マージ | 削除候補に含めない |
| detached HEAD | スキップ、ユーザーに通知 |
| リモートブランチなし + `review-*` 命名 | 削除候補に追加（一時ブランチと判断） |
| リモートブランチなし + その他 | スキップ、ユーザーに通知 |

---

## Step 4: 確認フェーズ（必須）

削除前に必ずユーザーに提示する。以下のフォーマットで表示：

```
以下のworktreeディレクトリとローカルブランチを削除します。よろしいですか？
（claude-context MCP 接続時は、対応する claude-context インデックスも併せて削除します）

【削除候補】
  1. /path/to/worktrees/feature-foo (150MB)
     ブランチ: feature/foo
     マージ先: main (PR #42, 2026-04-01)

  2. /path/to/worktrees/fix-bar (45MB)
     ブランチ: fix/bar
     マージ先: develop (PR #38, 2026-03-28)
     ⚠️ 未コミット変更あり

【スキップ】
  - /path/to/worktrees/wip-baz
     ブランチ: wip/baz
     理由: 未マージ
  - /path/to/worktrees/experiment
     理由: detached HEAD
  - /path/to/worktrees/local-only
     ブランチ: local-only
     理由: リモートブランチなし（push前の可能性）

削除してよいですか？（番号指定で一部のみ削除も可）
```

スキップ対象が0件の場合は【スキップ】セクションを省略する。

各候補に表示する情報:
- **ディスクサイズ**: `du -sh /path/to/worktree` で取得
- **マージ日**: `gh pr list --head <branch> --state merged --json mergedAt` から取得（gh CLI 利用時のみ）
- **未コミット変更**: Step 3-2 のチェック結果。変更がある場合は ⚠️ 警告を表示

ユーザーの応答:
- 「はい」「yes」「ok」→ 全件削除
  - **⚠️ 警告付きアイテムが含まれる場合**: 全件削除の前に追加確認を取る。「⚠️ 未コミット変更があるworktreeが含まれています。変更内容は破棄されます。それでも削除しますか？」
- 番号を指定（例：「1だけ」）→ 指定分のみ削除
- 「いいえ」「キャンセル」→ 削除しない

削除の承認は、対応する claude-context インデックスの削除（5-1.5）も含む。index 削除について別途の確認は取らない（claude-context MCP 接続時のみ実行）。

---

## Step 5: 削除実行

ユーザーが承認したworktreeを削除する。

### 5-1. worktree の削除

未コミット変更の有無に応じて削除方法を分ける:

```bash
# 未コミット変更なし → --force なしで削除
git worktree remove /path/to/worktrees/feature-foo

# 未コミット変更あり（Step 4 でユーザー承認済み）→ --force で削除
git worktree remove /path/to/worktrees/fix-bar --force
```

### 5-1.5: claude-context インデックスの削除（claude-context MCP 接続時のみ）

claude-context の `clear_index` が**ツールとして利用可能な場合のみ**、本サブステップを実行する。ツール自体が存在しない（MCP 未接続）環境では、本サブステップをスキップする（worktree 削除は 5-2 以降を通常通り実行）。

Step 4 で実際に削除を承認された各 worktree の絶対パスについてのみ `clear_index(path)` を呼ぶ。番号指定で一部のみ承認された場合は、その承認対象だけが対象となる。未承認・スキップした worktree の collection は消さない。`clear_index` は path の実在を要求しないため、worktree ディレクトリ削除後（本サブステップは 5-1 の後）でも有効。

承認対象には事前確認なしで無条件に `clear_index(path)` を呼んでよい（`get_indexing_status` は不要）。各呼び出しのレスポンスを次の3通りに分類する:

- **実削除**: `Successfully cleared codebase '<path>'` — Milvus collection と `~/.context/` 配下の snapshot を削除済み。
- **未 index（no-op）**: `Error: Codebase '<path>' is not indexed or being indexed.`（`isError` 形式）— その path は index されていない。**良性の no-op であり、失敗として扱わない。** worktree を個別 index していない運用ではこれが通常のレスポンス。
- **失敗**: `Failed to clear <path>: <message>`（`isError` 形式）— drop 処理自体が失敗。5-4 の完了報告で警告表示する。

削除候補が多数（十数件規模）の場合は、`clear_index` を順に呼ぶ間、処理中である旨を逐次示す。

このサブステップは付帯処理であり、`clear_index` の結果（未 index・失敗のいずれも）で後続処理（5-2 以降）を止めない。collection 削除は MCP ツール経由でのみ実行でき、`scripts/list-merged.sh` などの bash からは呼べない。

### 5-2. Git 内部参照の整理

すべての worktree 削除が完了した後、1回だけ prune を実行して後処理する。

```bash
# 削除後の後処理: 残存する内部参照を掃除
git worktree prune
```

### 5-3. ローカルブランチの削除

prune 後にローカルブランチを削除する。

Step 3 でマージ確認済みのため `-D`（強制削除）を使用する。`-d` は squash merge や rebase merge でコミット SHA が書き換わった場合に拒否されるため、マージ確認済みブランチには `-D` が適切。

```bash
# Step 3 でマージ確認済みのため -D は安全
# （squash/rebase merge ではコミット SHA が変わり -d が拒否される）
git branch -D feature/foo
git branch -D fix/bar
```

### 5-4. 完了報告

削除完了後に結果を報告：

```
✅ 削除完了
  - /path/to/worktrees/feature-foo (feature/foo)
  - /path/to/worktrees/fix-bar (fix/bar)

claude-context インデックス: 実削除 1 件 / 未 index で no-op 1 件 / 失敗 0 件
残りのworktree: 3件
```

- claude-context インデックスの行は claude-context MCP 接続時のみ表示する。未接続環境では出さない。
- 各件数は 5-1.5 のレスポンス分類を集計したもの（実削除 = `Successfully cleared` / no-op = `is not indexed or being indexed` / 失敗 = `Failed to clear`）。
- 「実削除 0 件（対象がすべて未 index）」が出る場合、worktree を個別 index する運用が空回りしている可能性に事後で気づける（Step 4 での事前 `get_indexing_status` 問い合わせは行わない）。

---

## 注意事項

- **メインのworktree**（最初のエントリ）は絶対に削除しない
- **fork からの PR** は `gh pr list --head` のスコープ外。fork ワークフローを使用している場合は手動確認が必要
- **claude-context インデックス削除は claude-context MCP 接続時のみ**実行する。未接続環境では従来通り worktree 削除のみを行う（`gh` + `git` で動作）
- この index 削除が実効するのは **worktree を個別に index している運用**の場合。本体（develop）のみ index している場合は `clear_index(worktree path)` が no-op となり回収されない（本体 collection に混入した worktree コードは本機能の対象外）
