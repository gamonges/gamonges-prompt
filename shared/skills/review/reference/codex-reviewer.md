# Codex のレビュアー（review / review-plan 共通）

`/review` と `/review-plan` が、Claude のレビュアーと並列に Codex（Codex plugin の companion）を 1 本走らせ、指摘を同じレポートに並べる手順。起動・待ち合わせ・結果の扱い・写し方の正本はこのファイルだけに置く（片方の skill だけ直す事故を避けるため）。呼ぶのはラッパー `~/.claude/scripts/codex-run.sh`（正本は `shared/scripts/codex-run.sh`。I/F はスクリプト冒頭のコメント）。

| | `/review` | `/review-plan` |
|---|---|---|
| 基底のパス | `tmp/review/codex-review.json` | `tmp/plan-review-codex.json` |
| 起動するコマンド | `codex-run.sh review --base <base_branch の値> --out <out>` | `codex-run.sh plan --plan <対象の計画ファイル> --out <out>` |
| 起動する位置 | Phase 3 の 3（Claude のレビュアーと同じターン） | フェーズ 1 の直後 |
| 待ち合わせる位置 | Phase 4 の 1 の先頭（他のレビュアーの結果を読む前） | フェーズ 4 の先頭（`plan-review.md` を書く前） |
| 書き出すファイル | `tmp/review/unified.md` | `tmp/plan-review.md` |

以下、`<out>` は「起動」の手順 1 で `new` が出したパス（実行ごとに違う）。

## 起動

1. 前景の Bash で `~/.claude/scripts/codex-run.sh new --out <上表の基底のパス>` を打ち、出た 1 行を `<out>` として、以後の起動と `wait` の両方に書き込む（例: `tmp/review/codex-review.20261019-203000-12345.json`）。実行ごとにパスが違うので、前回の遅い実行が後から終わっても今回の結果を上書きしない。`new` が rc≠0 か出力が空なら、起動も `wait` もせず「未実施（codex-run.sh new が rc=N）」と記録する
2. `Bash(run_in_background: true)` で上表のコマンドを起動し（`timeout` は指定しない）、Claude 側の作業を続ける。引数は値を書き込む（バックグラウンドの Bash は別の呼び出しで、前の呼び出しのシェル変数を持ち越さない。`$base_branch` のまま渡すと空になり `status:usage` で終わる）

Codex 上で動いているときも同じように起動する。ラッパーがすぐに exit 4 で `status:skipped` を書くので、結果は「省略」になる。

## 起動しなかった回

`/review-plan` に `--no-codex` が付いた回（`/plan-lgtm` の 2 回目以降）は、`new`・起動・`wait`・`<out>` の読み込みを**どれもしない**。記録は「省略（--no-codex）」の 1 行だけ。前回の `<out>` が残っていても読まない（残っているのは revise 前の計画に対する指摘で、今回の計画には当たらない）。

以下の「待ち合わせ」「待ちが切れたとき」「結果の扱い」は、起動した回だけの手順。

## 待ち合わせ

- 上表の「待ち合わせる位置」で、**前景の Bash で** `~/.claude/scripts/codex-run.sh wait --out <out> --timeout-sec 570` を 1 回呼ぶ。Bash ツールの `timeout` は `600000` にする
- バックグラウンドの完了通知が届いていても、同じように呼ぶ（すぐに戻る）
- 待つ間に**ターンを終えない**。`/plan-lgtm` の中だと、ループが止まったように見えるため
- 完了通知や Monitor を待ち合わせに使わない。どちらも非同期に届くだけで、モデルを止めない
- `wait` は `<out>` が現れれば、`status` によらず 0 で戻る

## 待ちが切れたとき

`wait` の終了コードが 0 以外なら、`<out>` を読まずに未実施として記録し、**統合ファイルはそのまま書く**。待ち直さない。

| `wait` の終了コード | 記録 |
|---|---|
| 3 | 未実施（待ち合わせの時間切れ） |
| 127 | 未実施（codex-run.sh が無い） |
| その他 | 未実施（wait が rc=N） |

- バックグラウンドの実行は止めない。Codex の turn は plugin の broker 側で走るので、ラッパーを止めても turn は止まらない。実行はそのまま終わるが、前回の実行は別のパスに書くので、今回の結果を上書きしない
- 統合ファイルを書いた後に完了通知が届いたら、統合ファイルを書き直さず、「Codex の結果は今回のレポートに反映しない」と 1 行だけ返す
- 統合ファイルを書かずに終えると、`plan-lgtm` が mtime で完了を確かめるところでループが止まる

## 結果の扱い

`wait` が 0 なら `<out>` を Read し、`status` で分岐する（exit code では分岐しない。バックグラウンドの exit code が待ち合わせの時点で手元にあるとは限らないため）。

| `status` | 扱い |
|---|---|
| `ok` | `result.findings` を下の「写し方」でレポートに並べる |
| `skipped` | 省略（実行者が Codex） |
| `unavailable`・`usage` | 未実施（`reason` をそのまま書く） |
| JSON が読めない・`status` が無い | 未実施（--out が読めない） |

- Codex の指摘は統合ファイルを書く時点で取り込み、後から Codex の結果だけを追記しない。`/review-plan` は `plan-lgtm` が mtime で完了を判定するので、`plan-review.md` 自体も 1 回だけ書く
- 未実施のときに、Claude で代わりのレビューを作らない。未実施であること自体を記録に残す
- Codex の指摘は捨てずに全件写す（`/review-plan` でも同じ）。誤りだと根拠（`file_path:L{number}`）で示せる指摘は、区分を Info（`/review-plan` では Note）に下げ、本文に反証を 1 行足して写す。下げた指摘は総合判定に数えない
- Codex の `verdict` だけで総合判定を決めない。写した指摘に、各 skill の既存の判定基準をそのまま当てる

## 写し方

| Codex の `severity` | `/review`（unified.md） | `/review-plan`（plan-review.md） |
|---|---|---|
| `critical`・`high` | ❌ Critical（`C-n`） | ❌ Critical（`C-n`） |
| `medium` | ⚠️ Minor（`M-n`） | ⚠️ Warning（`W-n`） |
| `low` | ℹ️ Info（`I-n`） | ℹ️ Note（`N-n`） |

- 出所の書き方（`<model>` は `<out>` の `model` から取る）:
  - `/review`: **エージェント**欄に `codex(<model>)`（例: `codex(gpt-6.1-sol)`）。カテゴリは本文から既存のタグを 1 つ選ぶ（迷えば `correctness`）。Info の書式にはエージェント欄が無いので、Codex の指摘を Info に写すときは Minor と同じ `**エージェント**: codex(<model>) | **確信度**: … | **カテゴリ**: …` の行を `**ファイル**:` の前に足す
  - `/review-plan`: 指摘ごとに `**出所**: Codex（<model>）` の行を足す
- 確信度（`/review` だけ。`/review-plan` のレポートには確信度の欄が無いので書かない）: `confidence` が 0.8 以上なら High、0.5 以上なら Medium、それ未満なら Low。**区分は上の表より先に確信度で決める**: Low なら `severity` によらず Info の下部に `(Low confidence)` を付けて置く（`/review` の既存の規則。Phase 5 の Critical にも数えない）
- 番号は Claude の指摘と通しで振る（`/fix` が `C-n`・`M-n` で出典を書くため）。各 skill の並べ替えを済ませてから、区分ごとに上から振る
- 重複: Codex の指摘と Claude の指摘が、同じファイルで行範囲が重なり、同じ問題を述べていれば 1 件にまとめる（Codex の指摘にはカテゴリが無いので、カテゴリタグでは照合しない）。Claude 側が節名で参照しているとき（`plan.md (ステップ 3)`）は、Codex の行がその節に入っていれば重なるとみなす
  - 区分は重い方、確信度は高い方、カテゴリは Claude 側のタグにする。見出し・参照・本文・修正案は Claude 側を使う
  - `/review` ではエージェント欄の末尾に既存の書式（`[code-quality・codex(gpt-6.1-sol)]`）で並べ、`/review-plan` では出所を `Claude と Codex の両方` にする
- 参照: `file` と `line_start`〜`line_end` を `file_path:L{number}` 形式に直す
  - `file` が対象の計画ファイルを指していれば（ラッパーは計画ファイルを絶対パスにして渡すので、絶対パスで返る）、計画ファイルの basename にする（`plan.md:L42`・`fix-plan.md:L42`）
  - repo 内の他のファイルは repo ルートからの相対パスにする
- 見出しは `title`、本文は `body`、修正案（推奨対応）は `recommendation` から取る（文章のままでよい）
- `/review` のフッタの参加エージェント一覧には、Codex の指摘を 1 件でも写したら（重複でまとめた分も含む）`codex(<model>)` を入れる

## 記録の文言

どの結果でも、統合ファイルのヘッダと完了報告の両方に、次のどれか 1 行を書く。括弧の中は決まった文言で、`未実施` のときだけ理由を書く（`skipped` の `reason` は書き足さない）:

- `**Codex レビュー**: 実施（<model>、<elapsed_sec> 秒、指摘 <件数> 件）`。件数は `result.findings` の件数（重複をまとめる前）。`<out>` の `dropped` が 1 以上なら、括弧の末尾に `、形の不正で除いた指摘 <dropped> 件` を足す（除いた指摘の生の出力は `<out>.raw.txt`）
- `**Codex レビュー**: 未実施（<理由>）`
- `**Codex レビュー**: 省略（実行者が Codex）`
- `**Codex レビュー**: 省略（--no-codex）`
