---
name: context-index
description: claude-context にコードベースを index して semantic search を可能にする。個人定義の ignorePattern（repo 外・非コミット）を参照し不要ディレクトリを除外する。`/context-index` で起動。
disable-model-invocation: true
---

# Context Index Skill

claude-context（Milvus + 埋め込み）にコードベースを index し、`search_code` での意味検索を可能にする。個人/ローカル定義の ignorePattern を参照して不要ディレクトリを除外する。

**規約**: CLAUDE.md の Skills 共通規約に従う

> index は副作用（埋め込み計算 + ベクトル storage）を伴うため、本 skill は / メニュー専用（Claude の自動呼出は無効）。

## パラメーター

引数なし。対象は**現在の作業ツリーの codebase ルート**（`git rev-parse --show-toplevel`）を自動で使う。

## ワークフロー上の位置付け

| 前工程 | 本コマンド | 後工程 |
|--------|-----------|--------|
| （任意）個人 ignore 定義の作成 | `/context-index` index 開始 | `/ask` `/design` 等で `search_code` を利用 |

## 実行条件

- **claude-context MCP が接続されていること**。`index_codebase` がツールとして利用可能でない（MCP 未接続）場合は、「claude-context MCP が必要」と報告して停止する（サイレント失敗にしない）。
- git リポジトリ内であること（絶対パス解決に `git rev-parse` を使う）。

## 実行プロセス

### Step 1: 絶対パスの解決

claude-context の全ツールは絶対パス必須。index 対象を解決する:

```bash
index_target=$(git rev-parse --show-toplevel)
```

worktree 内で実行した場合はその worktree の codebase ルートが対象になる（worktree ごとに別 collection）。

### Step 2: 個人 ignore 定義の読込

ignore パターンは repo の main ブランチにコミットせず、個人/ローカルファイルに定義する。本 skill がそれを読んで `index_codebase` の `ignorePatterns` に渡す。

repo キー（main repo 名。worktree でも共通）を導出し、対応する定義ファイルを読む:

```bash
common_dir=$(git rev-parse --git-common-dir)
main_root=$(cd "$(dirname "$common_dir")" && pwd)
repo_key=$(basename "$main_root")
ignore_file="$HOME/.claude/contextignore/${repo_key}.txt"
```

- `$ignore_file` が存在すれば、`#` で始まる行と空行を除いた各行を ignore パターン（配列）として読み込む。
- 存在しなければ空のまま続行する（デフォルト除外 + ルートの auto-read のみ適用）。あわせて定義ファイルの作り方を案内する（`./reference/personal-ignore.md`）。
- `index_target` 直下に**コミット済み `.contextignore`** があれば、claude-context が自動で読む旨を伝える（個人定義は加算で渡すため重複しても無害）。
- `index_codebase` スキーマは ignorePatterns を「ユーザー明示時のみ」とするが、**個人 ignore 定義ファイルの存在をユーザーの明示指定とみなして**渡す。定義が空/無しのときは ignorePatterns を省略する（既定の空配列）。

> 定義ファイルの形式・例・glob の癖は `./reference/personal-ignore.md` を参照。

### Step 3: index 状態の判定

`get_indexing_status(index_target)` を呼び、応答で分岐する（文字列の細部でなく `isError` フラグと `✅`/`🔄` マーカーで判定する）:

- **`isError` が返る**（未 index）→ 良性。Step 4 へ進んで index する。
- **応答に `✅` を含む**（index 済み）→ 再 index するか skip するかをユーザーに確認する。force 再 index を選んだ場合のみ Step 4 へ（`force=true`）。
- **応答に `🔄` を含む**（進行中）→ 既に indexing 中である旨を報告して終了する（二重起動しない）。

### Step 4: index 実行

```
index_codebase(path=index_target, ignorePatterns=<Step 2 の配列>, force=<Step 3 の判定>)
```

`force` は未 index のとき不要（既定 `false`）。`✅ indexed` で再 index を選んだ場合のみ `force=true` を渡す。

- success（「Started background indexing ...」）→ Step 5 へ。
- **`isError`「Error starting indexing: ...」**（Milvus/Ollama 未起動など backend の失敗）→ エラー内容を添えて「indexing 失敗（backend 未起動の可能性）」と報告して停止する。これは MCP 未接続（実行条件）とは別経路。

### Step 5: 進捗確認

index は background で進む。`get_indexing_status(index_target)` を 1〜数回確認する（`✅` 待ちで延々とループしない）:

- 応答に `✅` を含む → 完了として報告する。
- まだ `🔄`（進行中）なら、進捗 % を示して終了し「indexing は継続中。完了は後で `get_indexing_status` で再確認」と案内する。

## 注意事項

- worktree ごとに個別 index する運用では、worktree 数だけ埋め込みコスト（Ollama 計算 + Milvus storage）が増える。大規模・短命の worktree は index をスキップする判断も検討する。
- index した collection は worktree 削除時に孤児化しうる。`/worktree-cleanup` が削除時に `clear_index` で回収する。
- ignore パターンの簡易 glob の癖（真の `**`/`?` 非対応、dotfile/dotdir 常時除外、否定 `!` 非対応）は `./reference/personal-ignore.md` を参照。
