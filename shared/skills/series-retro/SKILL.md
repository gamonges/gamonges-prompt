---
name: series-retro
description: 完了したシリーズ（調査→計画→複数 PR→障害対応）をハーネスの観点で振り返り、hook・lint・構造まで含めた改善候補を出す。`/series-retro` で使用。
disable-model-invocation: true
---

1 つの作業シリーズ（調査 → grill → 計画 → 複数 PR → 本番の障害対応）が終わった後に、欠陥の流出・防御の層・アプローチの梯子の観点で振り返り、skill・hook だけでなく lint・テスト・製品コードの構造・基盤・組織まで含めた改善候補を出す。

エージェントが自分で整理すると、自分の得意な層（skill・指示文）に寄る。この skill は偏りを注意ではなく順序で防ぐ:

1. 独立レビュー（Codex、だめなら subagent）を、自分の一覧が**存在する前に**起動する
2. 自分の一覧（`self.md`）を、独立レビューの結果を**読む前に**書き終える
3. 両方の推奨の段を数えて表にし、段が割れたら独立レビューの側を既定にする

指定日の PR 群の振り返りは `retrospective`（別の skill）で行う。

出力先: `./tmp/series-retro/`（`prompt.md`・`prs/`・`run.json`・`self.md`・`review.md`・`retro.md`）。承認されたときだけ auto-memory と gamonges-prompt の issue に書く。

## 補助ドキュメントへの参照

**必ず読む**（起動したら必ず通るフェーズで使う）:

| 補助ドキュメント | 読むタイミング |
|------------------|----------------|
| `./reference/review-prompt.md` | Phase 2 で依頼文を組み立てる時 / Phase 4 で review.md の frontmatter を足す時 |
| `./reference/output-format.md` | Phase 3 で self.md を書く時 / Phase 5 で突き合わせる時 / Phase 6 で取り込み先を決める時 / Phase 7 で評価記録を書く時 |

**条件付きで読む**:

| 補助ドキュメント | 読むタイミング |
|------------------|----------------|
| `../series-sync/reference/series-format.md` | Phase 1 で series.md を読む時（`## 段` の列の意味） |

「念のため全部読む」は禁止。条件付きの表はトリガー条件に該当する場合のみ読み込む。

## 引数

```
/series-retro [<series.md のパス>] [--no-codex]
```

- 引数なし: `./tmp/series.md` を使う。無ければ、範囲（worktree と PR の一覧）を 1 問で尋ねる
- `--no-codex`: Codex を使わず、最初から subagent で独立レビューを行う

`$CR` は `~/.claude/scripts/codex-run.sh`、`$D` は `./tmp/series-retro`（どちらも本文の略記。実行するときは毎回展開して書く。zsh ではシェル変数に入れたコマンドが引数に分かれない）。

## 実行プロセス

### Phase 0: 既存の成果物

開始時に `$D` が在れば、次の表を**上から**当て、最初に当たった行で再開する。待ち中の Codex の実行は `<out>` の有無では見つからない（`codex-run.sh new` はパスを出すだけでファイルを作らない）ので、`run.json` で判定する。self の完了（行 2）は、独立レビューの結果を見る行（行 4・5）より先に確かめる。Codex は self より先に終わるのが普通なので、self を書き終える前に中断すると、再開で review を先に読む経路ができるため。

| # | 状態 | 再開する位置 |
|---|---|---|
| 1 | `retro.md` がある | 上書き / キャンセルを確かめる。上書きなら、`$D` の直下のファイルを `prs/` 以外すべて `$D/archive-<YYYYMMDD-HHmm>/` へ移してから Phase 1（残すと、前回の `review.md` が今回の独立レビューとして読まれる） |
| 2 | `review.md` か `<out>` がある。かつ `run.json` の `self_done` が true でない（`run.json` が無い・JSON でない・`self_done` が無いを含む） | `review.md` と `<out>` を**読まずに** Phase 3 の手順 4 を行い（書きかけの `self.md` は捨てて書き直す）、`self_after_review` を true にしてから、表を上から当て直す |
| 3 | `review.md` が空（0 バイト・空白だけ） | 消してから、表を上から当て直す |
| 4 | `review.md` がある | Phase 5 |
| 5 | `run.json` の `reviewer` が `codex` で、`out` のファイルがある | Phase 4 の抽出から（待たない） |
| 6 | `run.json` の `reviewer` が `codex` で、`out` のファイルが無い | `self_done` が true なら Phase 4 の待ちから（打ち切りの回数は 0 から数え直す）。true でなければ先に Phase 3 の手順 4 |
| 7 | `run.json` の `reviewer` が `subagent` か null（`review.md` が無い） | subagent はセッションを越えて残らないので、Phase 3 をやり直す（`subagent` なら手順 3 から、null なら手順 1 から）。`self_done` が true なら手順 4 は飛ばし、`after_self` を true にする |
| 8 | `prompt.md` があり、`run.json` が無いか、JSON でないか、`self_done` が無い | Phase 3 から（新しい実行は別のパスに書くので、前の遅い実行が今回を上書きしない） |
| 9 | それ以外（`prs/` だけなど） | Phase 1 から（写しは上書きする） |

`run.json` のキー: `reviewer`（`codex`・`subagent`・null）・`out`・`started_at`・`self_done`・`after_self`（独立レビューを self の後に起動した）・`self_after_review`（self を書いた時点で `review.md` か `<out>` が既に在った）。後の 2 つは Phase 5 が `retro.md` の実施状況に写す。

### Phase 1: 範囲と材料の目録

1. series.md の `## 段` から、PR（リポジトリと番号）・worktree・frontmatter の `outline`（横断計画）を取る。series.md が無ければ 1 問で範囲を尋ねる
2. 次を集めて「読むものの表」（資料・中身・在る／無い）を作る
   - 作業ディレクトリと各 worktree の `tmp/` の md（旧版 `*.archived-*` は名前と版の数だけ）。`tmp/series-retro/` は入れない（独立レビューに読ませるのは手順 3 の `prs/` の写しだけ。依頼文の「読む範囲」と同じ）
   - auto-memory の索引（`MEMORY.md`）から、シリーズに関わる記事と、このシリーズで再発した `feedback` の記憶
   - **前回までの評価記録**（`series-retro-*`）
   - auto-memory の置き場は、Claude Code では system prompt の Memory 節のディレクトリ、Codex では読み替え表（`~/.codex/AGENTS.md` の Codex 専用のブロック）の置き場
3. PR は 1 本につき 2 ファイルに写す（独立レビューは read-only で走り、`gh` を呼べるとは限らないため）。先に `mkdir -p tmp/series-retro/prs` を打つ
   - `gh pr view <n> --repo <owner>/<repo> --json title,body,comments,reviews > $D/prs/<owner>-<repo>-<n>-view.json`
   - `gh api --paginate --slurp repos/<owner>/<repo>/pulls/<n>/comments > $D/prs/<owner>-<repo>-<n>-comments.json`（`--slurp` が無いとページごとの配列が連結され、1 つの JSON にならない。`--slurp` の出力はページごとの配列を並べた配列）
4. 読むものの表を見せ、範囲を 1 問で確かめる（このまま・足す・外す）。無い worktree・資料は「無い」と表に残す（掃除の後に走らせたとき、黙って範囲が欠けないように）

### Phase 2: 依頼文

`./reference/review-prompt.md` の本体の差し込み口 6 個を埋め、`$D/prompt.md` に Write する。`{{SOURCES}}` は Phase 1 の表、`{{FOCUS}}` は材料から読んだ題材の固有の問いで埋める。書いた後に `rg -n '\{\{' tmp/series-retro/prompt.md` が 0 件であることを確かめる。`{{OUTPUT}}` は Phase 3 で決まる経路に合わせる（Codex の文面で書き、subagent に切り替えたら subagent へ渡す文面だけを差し替える）。

### Phase 3: 独立レビューの起動と一次の整理

**独立レビューの起動を、`self.md` を書くより先に済ませる。**

1. `--no-codex` でなければ、前景で `$CR new --out tmp/series-retro/codex-review.json` を打ち、出た 1 行を `<out>` とする。`$D/run.json` に `{"reviewer":"codex","out":"<out>","started_at":"<ISO 8601>","self_done":false,"after_self":false,"self_after_review":false}` を書いてから（Phase 0 から来て `run.json` が既にあれば、`self_done`・`after_self`・`self_after_review` は前の値を保つ。false に戻すと、書き終えた self を書き直すことになる）、`Bash(run_in_background: true)` で `$CR prompt --prompt tmp/series-retro/prompt.md --out <out>` を起動する（引数は値を書き込む）
2. 起動の直後に前景で `$CR wait --out <out> --timeout-sec 30` を 1 回呼ぶ
   - rc=0 で、出力の `status` が `skipped`（実行者が Codex）・`unavailable`・`usage` → 手順 3 に切り替える
   - rc=3（まだ走っている）、または rc=0 で `ok`（30 秒以内に終わった）→ Codex で進む。どちらも `<out>` は Phase 4 まで読まない
3. `--no-codex`・`new` の失敗・手順 2 の早い失敗のときは、役割を渡した subagent をバックグラウンドで起動する。渡すのは `prompt.md` の全文で、`{{OUTPUT}}` の位置は「`<作業ディレクトリ>/tmp/series-retro/review.md` に Write で書く。他のファイルは作らない・変えない」にする（Codex 上では、読み替え表のとおり汎用 agent の spawn になる）。`run.json` の `reviewer` を `subagent`、`out` を null、`started_at` を今の時刻に書き直す（他のキーは保つ。Phase 3 の初回なら `self_done`・`after_self`・`self_after_review` は false）
4. ここまで済んでから、**review の結果を読まずに** `self.md` を `./reference/output-format.md` の雛形で書き終え、`run.json` の `self_done` を true にする。`run.json` が無い・JSON でないときは `{"reviewer":null,"out":null,"started_at":null,"self_done":true,"after_self":false,"self_after_review":<Phase 0 の行 2 から来たなら true>}` で作り直す

### Phase 4: 待ち合わせ

- **開始トリガー**: `self.md` を書き終えた
- **反復トリガー**: 前景の `$CR wait --out <out> --timeout-sec 570`（Bash ツールの `timeout` は 600000）が rc=3（時間切れ）
- **完了条件**: `<out>` が在る（subagent の経路では、subagent の完了の通知が届き、`review.md` が空でない）
- **打ち切り**: 6 回（約 57 分）。到達したら待ちを止め、「Codex 実行中のため中断」と報告して、Phase 0 の表の行 6 から再開できることを案内する（turn は plugin の broker 側で続く）

`<out>` が現れたら `status` で分岐する:

| `status` | 扱い |
|---|---|
| `ok` | `result.text` を `review.md` に写す: `python3 -c 'import json,sys; sys.stdout.write(json.load(open(sys.argv[1]))["result"]["text"])' <out> > tmp/series-retro/review.md.part && mv tmp/series-retro/review.md.part tmp/series-retro/review.md`（直接 `review.md` に書くと、python3 の失敗で空の `review.md` が残る）。失敗したら `rm -f tmp/series-retro/review.md.part` して「JSON が読めない」と同じ扱いにする。先頭が `---` でなければ、`./reference/review-prompt.md` の「review.md の frontmatter」を前に付ける |
| `unavailable`・`usage`（長い実行の途中で落ちた） | subagent に 1 回だけ切り替えて（Phase 3 の手順 3）その完了を待つ。この回は `self.md` の後の起動になるので、`run.json` の `after_self` を true にする（Phase 5 が実施状況に「self の後に起動」と写す。独立性は依頼文の「読まない」の指示に頼る） |
| JSON が読めない | `unavailable` と同じ |

subagent も失敗したら、独立レビュー無しで Phase 5 へ進む（`./reference/output-format.md` の「独立レビューが未実施のとき」）。

### Phase 5: 突き合わせ

`./reference/output-format.md` の規則で `retro.md` を書く。実施状況には `run.json` の `after_self`・`self_after_review` を写す。段の分布の表を埋め、(a)・(b) に当たれば要するにに書く。前回までの評価記録があれば、その種類ごとに今回の再発の有無と回数を「前回からの再発」の表にする。

### Phase 6: 取り込み

`./reference/output-format.md` の取り込み先の表で下書きを作り、`retro.md` の「取り込み先ごとの下書き」に置く。

- 承認を取るのは、書き込みを伴う 2 つだけ（memory・gamonges-prompt の issue）。取り込み先ごとにまとめて尋ねる。問いは下書き 1 件ずつ自己完結させる（何の下書きか・書く場所・推奨を先頭に）
- memory の問いには、段 1 の改善案の記憶（`type: feedback`）と Phase 7 の評価記録（`type: project`）の下書きを**両方**並べ、どちらを書くかを分けて答えられるようにする
- gamonges-prompt の issue は、作る前に本文を非公開の語（作業ディレクトリのリポジトリ名・組織名・PR 番号・`prs/` の写しに出る人名）で検索して 0 件であることを確かめ、承認の後に `gh issue create --repo <gamonges-prompt の owner/repo>` で作る
- 製品のリポジトリのチケットは下書きを置くだけで、起票はオーナーが行う（問いを出さない）
- 承認されなかったものは「未起票（理由）」と書いて残す

### Phase 7: 評価の記録

Phase 6 で評価記録が承認されたときだけ、auto-memory（置き場は Phase 1 と同じ）に `./reference/output-format.md` の雛形で `series-retro-<slug>.md` を書き（既にあれば更新）、`MEMORY.md` に 1 行足す。不承認なら書かず、`retro.md` の現在地に「評価記録は未保存（不承認）。次回の再発の照合はこの回の分が欠ける」と書く。

### Phase 8: 完了報告

- 冒頭に「要するに」と決めること（無ければ「決めることなし」）
- 独立レビューの実施状況（Codex のモデルと所要／subagent に切り替えた理由／未実施）
- 段の分布の (a)・(b) の結果
- 取り込みの結果（書いた memory・作った issue・下書きだけのチケットの件数）
- 現在地（動いている作業・待っている判断・次にやること）
- HTML 化を 1 回提案する（`html-view` で `tmp/series-retro/retro.html`）
