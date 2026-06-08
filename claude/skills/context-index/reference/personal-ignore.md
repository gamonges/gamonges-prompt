# 個人 ignore 定義（personal contextignore）

`/context-index`（context-index skill）が参照する、claude-context indexing 用の ignore パターン定義。

## 置き場所

```
~/.claude/contextignore/<repo>.txt
```

- `<repo>` = main repo 名（`git rev-parse --git-common-dir` の親ディレクトリ名。worktree でも共通）。
- **repo の外**（ホーム配下）に置くため、repo の main ブランチにコミットされない。チーム運用が始まる前の個人最適に適する。
- ディレクトリが無ければ作成する: `mkdir -p ~/.claude/contextignore`
- 既知の限界: 異なる repo が同名 basename だと同一 `<repo>.txt` を共有し ignore が誤適用されうる（将来 remote URL のスラッグ化を検討）。

## 形式

- 1 行 1 glob パターン。
- `#` で始まる行はコメント、空行は無視。
- claude-context の `ignorePatterns` に**加算**で渡される（デフォルト除外・ルート直下の `.gitignore`/`.contextignore` の auto-read と併用）。

### 例

```
# ディレクトリ除外は末尾スラッシュ
build-output/
vendor/

# ファイルパターン（* のみ。basename にマッチ）
*.generated.ts
```

> `.git/` `.claude/` などドットで始まるディレクトリ/ファイルは**パターン不要で常に除外**される（後述「glob の癖」）。`.claude/worktrees/` も同様に index されないため、本体を index しても worktree は混入しない。

## glob の癖（claude-context 簡易 glob）

- ワイルドカードは `*` のみ（真の `**` / `?` は非対応。`**` も実質 `*` 相当）。
- マッチは **codebase ルート相対パス**。先頭 `/` でルートアンカー、末尾 `/` でディレクトリパターン。
- **dotfile / dotdir は常に除外**される（パターン不要）。
- gitignore の否定パターン `!pattern` は**非対応**。

## 2 段階移行（チーム運用開始後）

チームで claude-context 運用を始めたら、合意した普遍パターンを repo ルートの**コミット済み `.contextignore`** へ移す。claude-context はルート直下の `.contextignore` を自動で読む（git 追跡状態に依らない）ため、`/context-index` 側の変更は不要。個人定義ファイルには repo 固有の追加分だけを残す（コミット済み定義と個人定義は加算合成される）。
