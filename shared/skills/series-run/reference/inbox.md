# 横断の受信箱

並行して動く複数のシリーズ（1 シリーズ 1 coordinator）の「ユーザーを待っているもの」を、1 枚の HTML で見るためのもの。ビューは各シリーズの状態ファイルから決定的に導ける写しで、正本は状態ファイルのまま。coordinator は自分のシリーズの登録と、ビューの作り直しだけを行う（ほかのシリーズの状態ファイルには触れない）。

## 置き場所

- 登録簿: `~/.local/state/series-run/registry/` に 1 シリーズ 1 ファイル（名前は状態ファイルの絶対パスの sha1 の先頭 16 桁）。書き手はそのシリーズの coordinator だけなので、登録簿にロックは要らない
- ビュー: `~/.local/state/series-run/inbox.html`。作り直しは `inbox.lock` で排他にし、置き換えで書く（開いたままのビューは 60 秒ごとに読み直す）
- 置き場所は環境変数 `SERIES_RUN_STATE_DIR` で変えられる（テスト用）

## コマンド

```
python3 ~/.claude/skills/series-run/scripts/series_inbox.py register --state <状態ファイルの絶対パス> --terminal <handle> --title <series の title>
python3 ~/.claude/skills/series-run/scripts/series_inbox.py unregister --state <状態ファイルの絶対パス>
python3 ~/.claude/skills/series-run/scripts/series_inbox.py render
```

- `register`: 同じ状態ファイルの 2 回目は上書き（冪等）。`--terminal` はユーザーが答えを打ち込む terminal（adapter の「自分の terminal の識別子」）。別の terminal で再開したら、同じコマンドで新しい handle に上書きする
- `unregister`: 無いものも exit 0
- `render`: 出力先のパスを標準出力に 1 行で返す
- 終了コード: 0 成功 / 1 失敗（理由は標準エラー）/ 2 引数の誤り（argparse）。**失敗しても監督は止めない。** ビューは写しなので、SKILL.md の 7 の 4 の報告に出すだけにする。壊れた状態ファイルがあると render は失敗し、前のビューを残す

## 呼び出す時点

| 時点 | 操作 |
|------|------|
| 監督の開始（SKILL.md の 2 の 3 の後） | `register` と `render` |
| 再開（SKILL.md の 0 の「再開」、未処理の出来事を処理する前） | `register`（今の terminal で上書き）と `render` |
| `## ユーザー向け: 質問と回答の一覧` を書き直した後（SKILL.md の 4 の「質問と回答の一覧」） | `render` |
| 終わり（SKILL.md の 7 の 1 の報告の後） | `unregister` と `render` |
| 中断（監督を止めて後で再開する） | 何もしない（登録を残す。再開で上書きする） |

## ビューに出るもの

シリーズごとに、題名・答える terminal・状態ファイルのパスと、次の 3 つ。

- **待っているもの**: `## ユーザー向け: 質問と回答の一覧` の `### 待っているもの` の本文（そのまま写す。URL はリンクにする）
- **推奨で進めたもの**: `### 答えが出たもの` のうち `推奨で進めた` を含む行（③の 3 段目。覆すなら番号で答える）
- **作業単位**: `## 作業単位` の各行の段・現在地・待っている相手・次と、`<worktree>/tmp/meaning-card.html` があればそのリンク（`./meaning-card.md`）

状態ファイルが無いシリーズと、全作業単位が `完了` か `対象外` のシリーズは「終わった（登録が残っている）」と出る。終わりの `unregister` を忘れた登録の残りで、ユーザーが見て消してよい（`unregister`）。

節は、コードの囲みの外の見出しで引く（状態ファイルの例のブロックの中の見出しを拾わない）。状態ファイルの書式は変えない（`./state-format.md`）。
