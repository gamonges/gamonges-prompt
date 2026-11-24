# Codex への依頼

`review-adr` の Phase 3（起動）と Phase 4（待ち合わせ・写し）で、Codex を 1 本走らせる手順。`--no-codex` のときはこのファイルの手順をどれも行わない。

起動・待ち合わせ・待ちが切れたときの扱いの正本は `../../review/reference/codex-reviewer.md`（「起動」「待ち合わせ」「待ちが切れたとき」）。ここに写しを持たず、違う点だけを書く。

| | `review-adr` |
|---|---|
| 基底のパス | `tmp/adr-review/codex.json` |
| 起動するコマンド | `~/.claude/scripts/codex-run.sh prompt --prompt tmp/adr-review/_codex-prompt.md --out <out>` |
| 起動する位置 | Phase 3（観点の実行役と同じターン） |
| 待ち合わせる位置 | Phase 4 の先頭（観点の結果をファイルに書く前） |

## 依頼文（`tmp/adr-review/_codex-prompt.md`）

下の雛形の `{…}` を埋めて Write する。書いた後に、雛形の変数名を固定文字列で数えて埋め残しが 0 件であることを確かめる（`\{[^}]*\}` のような形の検査は、ADR の本文から写した `{organizationId}` や JSON の波括弧を埋め残しと誤認するため、雛形にある 10 個の変数名だけを数える）:

```bash
rg -n -F -e '{ADR のタイトル}' -e '{立場}' -e '{深さ}' -e '{_target.md の絶対パス}' -e '{_comments.md の絶対パス}' -e '{_lineage-*.md の絶対パスの一覧。無ければ「なし」}' -e '{対象 repo の絶対パス}' -e '{self（書いた人の友人として、直し方を厚く）| review（承認する人として、承認してよいかを問う）}' -e '{選んだ新しい観点ごとに 1 行: `- <観点名>: <questions.md の絶対パス>`}' -e '{finding-format.md の絶対パス}' tmp/adr-review/_codex-prompt.md
```

rc=1（一致なし）なら埋め残しなし。rc=0 は埋め残しあり、rc=2（読めない）も埋め残しありと同じに扱う。雛形の変数を足したら、この一覧にも足す。`prompt` モードは返った本文を JSON として解釈しないので、出力の形は依頼文で決めるしかない。

<!-- tmp-frontmatter: tmp/adr-review/_codex-prompt.md -->
```markdown
---
type: ADR Review
title: Codex への依頼 — {ADR のタイトル}
description: review-adr が Codex に渡す依頼文。{立場}の立場で、{深さ}の観点の問いを 1 本で当てる
status: stable
---
# ADR のレビューの依頼

あなたは読み取り専用のレビュアー。ファイルを作らず・変えず、結果は最終メッセージに全文で書く。

## 対象

- 対象の ADR: {_target.md の絶対パス}
- コメント: {_comments.md の絶対パス}
- 参照先の ADR: {_lineage-*.md の絶対パスの一覧。無ければ「なし」}
- 対象 repo: {対象 repo の絶対パス}（コードと git は読んでよい）
- 立場: {self（書いた人の友人として、直し方を厚く）| review（承認する人として、承認してよいかを問う）}

## 当てる観点

次の観点の問いを読み、ADR に当てる。問いの本文はファイルにある。

{選んだ新しい観点ごとに 1 行: `- <観点名>: <questions.md の絶対パス>`}

あわせて、次を見る: 判断の基準と代替案の比較が結論を支えているか、事実の主張がコードと合っているか、1 年後の失敗の原因、移行と撤退の段取り、前の ADR との整合。

## 出力の形

{finding-format.md の絶対パス} の「雛形」と「書き方の規則」に従う。指摘の ID の略号は `CX`（`### CX-1. …`）。観点名は「Codex」。frontmatter から書く。

- 全件を出す（確信度・重大度が低くても捨てない）
- 指摘が 0 件なら「指摘」の見出しの下に `指摘なし` の 1 行
- 判断そのものが覆る指摘にだけ、札 `再判断` を付ける
```

## 結果の扱い

Phase 4 の先頭で、前景の Bash で `~/.claude/scripts/codex-run.sh wait --out <out> --timeout-sec 570`（Bash ツールの `timeout` は `600000`）を呼ぶ。`wait` が 0 なら `<out>` を Read し、`status` で分岐する。

`wait` が 3（待ち合わせの時間切れ）で返ったら、同じコマンドで `wait` を**もう 1 回だけ**呼ぶ（合計で最大 1140 秒待つ）。これは正本（`../../review/reference/codex-reviewer.md` の「待ちが切れたとき」の「待ち直さない」）と違う点。ADR の依頼文は長く、Codex の所要時間が 1 回の上限 570 秒に近い（試しで 483〜584 秒）ため。570 秒を延ばさないのは、1 回の `wait` を前景の Bash の上限 600 秒（`codex-run.sh` の `DEFAULT_WAIT_SEC` の注記）より前に戻すため。`wait` は `--out` を消さずに待つだけなので、2 回目もそのまま続きを待てる。2 回目も 3 なら、下の「待ちが切れたとき」の扱い（未実施）にし、3 回目は呼ばない。3 以外の 0 でない終了コードでは待ち直さない

| `status` | 扱い | `unified.md` の Codex の状態行 |
|---|---|---|
| `ok` | `result.text` を `tmp/adr-review/codex.md` に写す（下） | `**Codex**: 実施（<model>、<elapsed_sec> 秒）` |
| `skipped` | 写さない | `**Codex**: 走らなかった（実行者が Codex）` |
| `unavailable`・`usage` | 写さない | `**Codex**: 走らなかった（<reason>）` |
| JSON が読めない・`status` が無い | 写さない | `**Codex**: 走らなかった（--out が読めない）` |

`wait` が 0 以外・`new` の失敗は、`../../review/reference/codex-reviewer.md` の「待ちが切れたとき」の表の理由で `**Codex**: 走らなかった（<理由>）` にする。`--no-codex` なら `**Codex**: 走らなかった（--no-codex）`。走らなかったときは、`unified.md` の先頭にも `> Codex は走らなかった（<理由>）` の 1 行を置く。

### `codex.md` への写し方

1. `python3 -c 'import json,sys; sys.stdout.write(json.load(open(sys.argv[1]))["result"]["text"])' <out> > tmp/adr-review/codex.md.part` で本文を取り出す（失敗したら `rm -f tmp/adr-review/codex.md.part` して「--out が読めない」と同じ扱いにする）
2. `finding-format.md` の「形の不正の判定」の手順 0（前置きを捨てる）を `codex.md.part` に当てる。その後も先頭の行が `---` でなければ、`finding-format.md` の雛形の frontmatter（観点名「Codex」）を前に付ける
3. `mv tmp/adr-review/codex.md.part tmp/adr-review/codex.md`
4. `finding-format.md` の「形の不正の判定」の 2・3 を当てる（1 は手順 2 で満たしている。コードフェンスの中の行を数えないので、フェンスの中の雛形の例だけでは通らない）。当たれば状態行の括弧の末尾に `、形の不正` を足し、Codex の指摘は集約に入れない。総合判定は止めない
