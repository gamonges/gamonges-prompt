---
name: worktree-cleanup
description: マージ済み PR の worktree を一括削除する。「worktree を掃除」「worktree cleanup」「マージ済み worktree を削除」等のキーワードで呼び出す。`claude -w` で作った worktree が溜まったときの定期整理に使用。
disable-model-invocation: true
---

# Worktree Cleanup Skill

`claude -w` で作成したworktreeを、PRマージ後にまとめて削除するためのスキル。

## 同梱 scripts

| script | 用途 |
|--------|------|
| `./scripts/list-merged.sh` | マージ済 PR と対応 worktree を 1 コマンドで列挙する。Step 1-3 の手順を最小実装で取得したい時に使う |
| `./scripts/find-orphan-collections.mjs` | Milvus に残った claude-context の孤児 collection を検出し、承認されたものだけを drop する。Step 6 で使う |

実行例:

```bash
./scripts/list-merged.sh
```

`gh` 認証が必須。詳細な判定（未コミット変更チェック等）は本 SKILL の手順を参照。

## 補助ドキュメント

| 補助ドキュメント | 読むタイミング |
|------------------|----------------|
| `./reference/orphan-check.md` | Step 6 を実行する時 |

## 概要フロー

1. **前処理** — リモート同期と無効参照の掃除
2. **一覧取得** — 現在のworktreeとチェックアウト中ブランチを列挙
3. **マージ済み判定 + 状態チェック** — マージ状態と未コミット変更を確認
4. **確認フェーズ** — 削除候補をユーザーに提示して確認を取る
5. **削除実行** — 承認されたworktreeのみ削除（claude-context MCP 接続時は対応するインデックスも削除）
6. **孤児点検** — Milvus に残った孤児 collection を検出し、承認後に drop（Milvus に到達できる場合のみ）

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

削除の承認は、対応する claude-context インデックスの削除（5-1）も含む。index 削除について別途の確認は取らない（claude-context MCP 接続時のみ実行）。index 削除は worktree 削除の前に行うため、worktree の削除に失敗しても index は削除済みになる。

---

## Step 5: 削除実行

ユーザーが承認したworktreeを削除する。

### 5-1. claude-context インデックスの削除（claude-context MCP 接続時のみ）

claude-context の `clear_index` が**ツールとして利用可能な場合のみ**、本サブステップを実行する。ツール自体が存在しない（MCP 未接続）環境では、本サブステップをスキップする（5-2（worktree 削除）以降は通常通り実行する）。

Step 4 で実際に削除を承認された各 worktree の絶対パスについてのみ `clear_index(path)` を呼ぶ。番号指定で一部のみ承認された場合は、その承認対象だけが対象となる。未承認・スキップした worktree の collection は消さない。`clear_index` は対象パスが**実在するディレクトリ**であることを要求し、削除後に呼ぶと `does not exist` を返して collection を drop しない。そのため worktree 削除（5-2）の**前**に呼ぶ。

承認対象には事前確認なしで無条件に `clear_index(path)` を呼んでよい（`get_indexing_status` は不要）。各呼び出しのレスポンスを次の 3 通りに分類する。失敗は応答を列挙して当てはめるのではなく「実削除・no-op のどちらでもないものすべて」とする。列挙式にすると、版上げで増えた応答が集計からも警告からも黙って消えるため:

- **実削除**: `Successfully cleared codebase '<path>'` — Milvus collection と `~/.context/` 配下の snapshot を削除済み。
- **no-op**: 次の 2 種。**良性の no-op であり、失敗として扱わない。**
  - `Error: Codebase '<path>' is not indexed or being indexed.`（`isError` 形式）— その path は index されていない。worktree を個別 index していない運用ではこれが通常のレスポンス。`indexfailed`（index が途中で失敗した）の worktree もこの応答を返し、途中まで書かれた collection が残ることがある。その場合は worktree 削除後に Step 6 で孤児として拾われる。
  - `No codebases are currently indexed or being indexed.` — 何も index されていない。
- **失敗**: 上記以外のすべて。応答の本文をそのまま 5-5 の完了報告で警告表示する。例: `does not exist`・`is not a directory`・`Failed to clear <path>: <message>`・`Error clearing index: <message>`（例示であり、ここに無い応答も失敗に分類する）。

対象パスで index が実行中の場合、`clear_index` はその index を中断し、停止を待ってから削除する（index の完了は待たない）。削除候補が多数（十数件規模）の場合も含め、`clear_index` を順に呼ぶ間は処理中である旨を逐次示す。

このサブステップは付帯処理であり、`clear_index` の結果（no-op・失敗のいずれも）で後続処理（5-2（worktree 削除）以降）を止めない。worktree 単位の回収は `clear_index`（snapshot も同時に更新される）で行う。Milvus を直接 drop する経路は Step 6 の孤児点検だけが使う。

### 5-2. worktree の削除

未コミット変更の有無に応じて削除方法を分ける:

```bash
# 未コミット変更なし → --force なしで削除
git worktree remove /path/to/worktrees/feature-foo

# 未コミット変更あり（Step 4 でユーザー承認済み）→ --force で削除
git worktree remove /path/to/worktrees/fix-bar --force
```

各 remove の成否と stderr を記録する。失敗しても残りの remove は続ける。

全件を試した後に失敗が 1 件以上あれば、次の形式で提示して**再 remove するかを確認する**（多くの場合、5-1 で index だけが消えて worktree が残った状態になっている）:

```
⚠️ 以下の worktree は削除に失敗しました（claude-context インデックスは削除済み）:
  1. /path/to/worktrees/feature-foo (feature/foo)
     エラー: <git worktree remove の stderr>
再 remove しますか？（番号指定で一部のみも可 / 「いいえ」で残す）
```

- 再 remove は `--force` を付けて 1 回だけ行う。
- lock されている worktree（`git worktree list --porcelain` の該当エントリに `locked` 行がある）は、`--force` 1 つでは削除できない。その旨と lock 理由（`locked` 行の後ろ）を示し、`--force --force` で行うかを別途確認する。lock の判定は stderr の文言ではなく porcelain で行う（stderr はロケールで変わりうる）。lock は明示的な保護なので、他の再 remove と承認をまとめない。
- 再 remove も失敗したもの・「いいえ」で残したものは「残存」として 5-5 で報告し、それ以上は繰り返さない。

「インデックスは削除済み」の注記（この提示文と 5-5 の残存行）は、その worktree の 5-1 が実削除だった場合にだけ付ける。no-op・失敗の場合、および MCP 未接続で 5-1 をスキップした場合は省く（no-op でも `indexfailed` の途中までの collection が残っていることがあり、index が残っているのに削除済みと報告しないため）。

### 5-3. Git 内部参照の整理

すべての worktree 削除が完了した後、1回だけ prune を実行して後処理する。

```bash
# 削除後の後処理: 残存する内部参照を掃除
git worktree prune
```

### 5-4. ローカルブランチの削除

prune 後にローカルブランチを削除する。5-2 で残存した worktree のブランチは削除対象から外す（チェックアウト中のブランチは `git branch -D` が拒否する。失敗を警告として出すより、先に外すほうが報告が明確になる）。

Step 3 でマージ確認済みのため `-D`（強制削除）を使用する。`-d` は squash merge や rebase merge でコミット SHA が書き換わった場合に拒否されるため、マージ確認済みブランチには `-D` が適切。

```bash
# Step 3 でマージ確認済みのため -D は安全
# （squash/rebase merge ではコミット SHA が変わり -d が拒否される）
git branch -D feature/foo
git branch -D fix/bar
```

### 5-5. 完了報告

削除完了後に結果を報告：

```
✅ 削除完了
  - /path/to/worktrees/feature-foo (feature/foo)
  - /path/to/worktrees/fix-bar (fix/bar)

claude-context インデックス: 実削除 1 件 / no-op 1 件 / 失敗 0 件
残りのworktree: 3件
```

5-2 で残存した worktree がある場合は、次の行を足す:

```
⚠️ 削除できなかった worktree（インデックスは削除済み）:
  - /path/to/worktrees/feature-foo (feature/foo) — 再度使う場合は /context-index で index を作り直す
```

- claude-context インデックスの行は claude-context MCP 接続時のみ表示する。未接続環境では出さない。
- 各件数は 5-1 のレスポンス分類を集計したもの（実削除 = `Successfully cleared` / no-op = `is not indexed or being indexed` と `No codebases are currently indexed` / 失敗 = それ以外すべて）。失敗が 1 件以上あれば、その応答本文を警告として併記する。
- 「実削除 0 件（対象がすべて未 index）」が出る場合、worktree を個別 index する運用が空回りしている可能性に事後で気づける（Step 4 での事前 `get_indexing_status` 問い合わせは行わない）。

---

## Step 6: 孤児点検

Step 5 の後に、Step 5 で削除した worktree が 0 件でも実行する（主な対象は skill 外で削除された worktree の collection のため）。手順・判定の定義・承認の取り方は `./reference/orphan-check.md` に従う。

```bash
node ~/.claude/skills/worktree-cleanup/scripts/find-orphan-collections.mjs
```

- skill は対象リポジトリを cwd として実行されるため、repo 相対のパスでは解決できない。install 後の絶対パスで呼ぶ
- 点検した Milvus（stdout の `milvus` / `milvusSource`）を報告に必ず含める。利用者が点検先を目で確かめられるようにするため
- 終了コード 2 なら「Milvus に到達できないため孤児点検をスキップ」と明示して終える。終了コード 1 なら stderr を警告として示し、「孤児 0 件」とは報告しない
- drop の承認は Step 4 とは**別に**取る（worktree と無関係な collection を消すため）。点検先が `localhost` 以外の場合は reference の「注意」（共有 Milvus）を先に確認する

---

## 注意事項

- **メインのworktree**（最初のエントリ）は絶対に削除しない
- **fork からの PR** は `gh pr list --head` のスコープ外。fork ワークフローを使用している場合は手動確認が必要
- **claude-context インデックス削除は claude-context MCP 接続時のみ**実行する。未接続環境では従来通り worktree 削除のみを行う（`gh` + `git` で動作）
- この index 削除が実効するのは **worktree を個別に index している運用**の場合。本体（develop）のみ index している場合は `clear_index(worktree path)` が no-op となり回収されない（本体 collection に混入した worktree コードは本機能の対象外）
- **skill 外で削除した worktree の collection は Step 5 では回収できない**（`clear_index` は実在するパスにしか効かない）。Step 6 の孤児点検で回収する
