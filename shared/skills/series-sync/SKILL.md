---
name: series-sync
description: シリーズの PR の状態を GitHub から実測して series.md に書き、確認の後に各 PR の全体像を同期する。`/series-sync` で使用。
disable-model-invocation: true
---

> **`/series-sync` と明示して起動する。** 自然言語からは起動しない。create-pr・stack-pr-submit は、この SKILL.md の「同期の手順」を読んで同じ手順を行う（`Skill` ツールでは呼べないため）。

シリーズ（1 つの対応を複数の PR に分けたもの）の全 PR の本文の先頭に、同じ全体像を置く。PR ごとに変わるのは強調の箇所だけ。全体像の完成形は series-init が `series.md` に 1 回だけ組み、同期はスクリプトが差し替えるだけにする（毎回組み直すと PR の間で図が食い違うため）。

## 補助ドキュメントへの参照

**必ず読む**:

| 補助ドキュメント | 読むタイミング |
|------------------|----------------|
| `./reference/series-format.md` | 起動したら最初に（series.md の契約・目印・置き換えの規則・error の理由の正典） |

## パラメーター

`series-sync [<series.md>] [--migrate]`

- series.md のパス: 指定が無ければ `./tmp/series.md`。それも無ければ、作業中の worktree の `tmp/context.md` の frontmatter の `series:` の値
- `--migrate`: ユーザーが移行（目印の無い古い全体像の置き換え）を明示したときだけ使う。既定では目印の無い全体像を書き換えない（fail-closed）

## ワークフロー上の位置付け

| 前工程 | 本コマンド | 後工程 |
|--------|-----------|--------|
| `/series-init`（series.md を作る） | `/series-sync`（任意の時点で再実行してよい） | — |
| `/create-pr`・`/stack-pr-submit`（PR を作った直後に、同じ手順を内部で行う） | 進捗の更新・未登録の PR の登録・キャンセルした同期のやり直し | — |

## スクリプトの I/F

呼び方: `python3 ~/.claude/skills/series-sync/scripts/series_sync.py <サブコマンド> …`（skill は対象リポジトリを cwd にして動くので、install 後の絶対パスで呼ぶ。`.py` に実行ビットは付かないので `python3` を前に置く）

| サブコマンド | GitHub | series.md | 出力 | 終了コード |
|-------------|--------|-----------|------|-----------|
| `check <series.md>` | 読まない | 読む | 問題を 1 行 1 件 `error: …` | 0 / 1 |
| `render <series.md> --stage S [--body-file F] [--migrate]` | 読まない | 読む | `--body-file` 無し: ブロック。あり: F にブロックを当てた本文 | 0 / 1（当てられない） |
| `register <series.md> --repo O/R --branch B --pr N [--stage S] [--worktree P]` | 読まない | 段の行を書く | `registered: …` / `unchanged: …` / 候補の一覧 | 0 / 1（表を壊す値・`--repo` の形） / **3**（曖昧・衝突・候補なし・別の段に同じ PR。人が段を決める） |
| `write <series.md> --from F [--drop S …]` | 読まない | 全体を書く（series-init 専用） | `written: …`・`inherited: …`・`reset: 段 <段> のブランチ <B>（<旧 O/R> のもの）を引き継がない`・`dropped: <段> <O/R#N>` | 0 / 1（F が check を通らない。今の series.md の表が壊れている） / **3**（登録済みの段が F にも `--drop` にも無い。F のブランチ・PR が今の値と違う。PR が登録済みの段のリポジトリが変わった。引き継いだ後に同じ PR が 2 つの段に入る） |
| `status <series.md>` | 読む | `## 進捗` と `timestamp` を書く | 進捗の表と `warning: …` | 0 / 1（GitHub の読み取りに失敗） |
| `plan <series.md> [--out DIR] [--migrate]` | 読む（GET） | 読む | PR ごとに `O/R#N <状態> <insert\|replace\|migrate\|none\|error> [理由]`、`changes: X / errors: Y`、`dir: <DIR>` | 0 / 1（check の失敗、error の PR がある） |
| `apply --plan DIR [--only O/R#N …]` | 読む・**書く**（PATCH） | 読まない | PR ごとに `written` / `unchanged` / `skipped` / `mismatch` / `failed` | 0 / 1（skipped・mismatch・failed がある。`--only` の PR が plan に無い） |

- `plan` の DIR の既定は `<series.md のディレクトリ>/series-sync/<YYYYmmdd-HHMMSS>/`。同じ名前があれば `-2`・`-3` を付ける。実際の DIR は出力の `dir:` の行で知る。DIR には `plan.json`・`*.before.md`（GitHub の今の本文）・`*.after.md`（書く本文）が残る
- `plan` が exit 1 でも、error でない PR の plan は DIR に書かれている（error の PR は `apply` で書かれない）。check の失敗のときだけは何も書かない
- `apply` は本文を読み直し、after と同じなら `unchanged`（書かない）、plan の時点（before の sha256）から変わっていれば `skipped`（書かない）、どちらでもなければ PATCH して読み直し、after と違えば `mismatch`。同じ DIR で何度やり直しても、書き終えた PR を二重に書かない
- GitHub への書き込みは `gh api -X PATCH repos/<O/R>/pulls/<N> --input <DIR>/<…>.patch.json` だけ（`gh pr edit` は Projects (classic) のエラーで失敗するリポジトリがあるため）

## 同期の手順

この節が同期の手順の正典で、create-pr の Phase 6.5 と stack-pr-submit のステップ 5.5 もこの手順に従う（手順が止まった・キャンセルされたときも、呼び出し元はその結果を持って自分の報告へ進む）。`$S` は series.md のパス、`$SYNC` は `python3 ~/.claude/skills/series-sync/scripts/series_sync.py`（`$SYNC` は本文の略記。実行するときは毎回展開して書く。シェル変数に入れて `$SYNC check …` とすると、zsh では引数に分かれずに失敗する）。

1. `$SYNC check "$S"`。exit 1 → 止めて `error:` の行を報告する（series.md を直すか、`/series-init` で組み直す）
2. `$SYNC status "$S"`。進捗の表を見せる。`warning:` の未登録の PR があれば報告し、登録するかを尋ねる（登録は `$SYNC register "$S" --stage <段> --repo <O/R> --branch <B> --pr <N>`）。`… 件以上あり、それ以降は調べていない` の warning は登録の候補ではなく、未登録の PR を調べ切れていないこととして報告する。exit 1 → GitHub の読み取りの失敗を報告して止める
3. `$SYNC plan "$S"`（ユーザーが移行を明示したときだけ `--migrate`）。exit 1 でも出力に `dir:` の行があれば手順 4 へ進む（error の PR があるだけで、他の PR の plan は書かれている）。`dir:` の行が無ければ check の失敗として止めて報告する
4. 書く PR が無いとき:
   - `changes: 0` かつ `errors: 0` → 「本文の変更なし」と報告して終わる（変わらない同期では何も書かない）
   - `changes: 0` で、error が `heading-only:` だけ（`--migrate` 無しの plan）→ 「`--migrate` で plan をやり直す／何もしない」を尋ねる。やり直したら手順 4 から進める
   - `changes: 0` で、それ以外の error がある → 確認せずに error を報告して終わる
5. 一覧（PR・状態・insert／replace／migrate・error の理由）と、描画したブロックを 1 本分（`dir:` の DIR の `*.after.md` のどれか）見せ、**1 回だけ**確認する: 「N 本の PR の全体像を書き換える／キャンセル」
   - マージ済みの PR も一覧に含まれる（同期はマージ済みの本文も書き換える）。止めたい PR があれば、ここで `--only` の対象から外せる
   - `heading-only:` の error があり、`--migrate` 無しの plan だったとき: 同じ質問に「`--migrate` で plan をやり直し、その PR の既存の全体像も置き換える」を選択肢として足す（シリーズを作る前に `/create-pr` した単独の PR が、後から登録されたときに必ず通る）。選ばれたら手順 3 を `--migrate` でやり直し、手順 5 の確認をもう一度だけ行う
   - `markers:`・`migrate:`・`too-long:`・`gh:` の error は報告だけにする（本文を手で直してから、もう一度 `/series-sync`）
6. 承認 → `$SYNC apply --plan <DIR>`（一部だけなら `--only O/R#N` を並べる）。`skipped` は「plan の後に本文が変わったので、plan からやり直す」と案内する。`mismatch` は GitHub で本文を確かめるよう報告する。どちらも自動で再試行しない
7. 報告: 書いた PR・unchanged・skipped・mismatch・failed・error と、plan の DIR（前の本文は DIR の `*.before.md` に残る）

**キャンセルしたとき**: 本文は書かれない（新しい PR には全体像が入らない）。後で `/series-sync` を実行すれば入る、と報告する。

**同期の実行中に series.md を手で編集しない。** スクリプトの書き込みはロックの中で読み直してから行うが、人の手編集はロックの外にある。

## 戻すとき

plan の DIR の `*.before.md` を `{"body": …}` の JSON にして PATCH し直す（GitHub の PR の編集履歴にも前の本文が残る）。

```bash
python3 -c 'import json,sys; json.dump({"body": open(sys.argv[1], encoding="utf-8", newline="").read()}, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)' \
  "<DIR>/acme__api__12.before.md" "<DIR>/acme__api__12.restore.json"
gh api -X PATCH repos/acme/api/pulls/12 --input "<DIR>/acme__api__12.restore.json"
```

## 報告の形

```
## シリーズの同期: <title>

- 進捗: <status の表>
- 警告: <warning の行。無ければ「なし」>
- 書いた PR: acme/api#12（replace）, acme/web#5（insert）
- 変わらなかった PR: …
- 書かなかった PR: acme/api#13（skipped: plan の後に本文が変わった）
- plan の DIR: <DIR>（前の本文は *.before.md）
```
