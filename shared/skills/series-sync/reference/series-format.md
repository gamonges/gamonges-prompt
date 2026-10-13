# series.md の契約（正典）

シリーズ（1 つの対応を複数の PR に分けたもの）の構成と進捗の正本 `series.md` の形式。`series-init`（作る）・`series-sync`（同期する）・`create-pr`／`stack-pr-submit`（PR を登録する）がこのファイルを参照し、各 skill には写しを置かない。形式はスクリプト `../scripts/series_sync.py` の `check` が強制し、挙動テスト `shared/scripts/tests/test-series-sync.sh` が固定する（契約とパーサが食い違えばテストが落ちる）。

PR の本文に描く全体像の見た目（見出し・凡例・classDef・表の列）は `../../create-pr/reference/pr-description-template.md` の「全体像ブロック」が正典で、ここには書かない。

## 置き場所と失ったとき

- 横断計画（シリーズ全体の実装計画）の隣に置く。例: `<横断計画の worktree>/tmp/series.md`
- 各リポジトリの worktree からは、`tmp/context.md` の frontmatter の `series:` で絶対パスを引く
- series.md だけを復元する手段は持たない。series.md は横断計画と同じ `tmp/` にあり、series.md を失う経路では横断計画も失われる。失ったら `/series-init` で作り直し、PR を `register --stage` で登録し直す。PR の本文には目印が残っているので、移行（`--migrate`）は要らない

## frontmatter

| キー | 必須 | 値 |
|------|------|-----|
| `type` | — | `Series` |
| `title` | — | 対応の名前 |
| `outline` | ✅ | 横断計画の絶対パス |
| `branch_prefix` | — | このシリーズのブランチの接頭辞。カンマ区切りで複数。`status` が未登録の PR を探すのに使う |
| `timestamp` | — | 最後に `status` を実行した時刻（ISO 8601） |

## 節と書き手

```markdown
---
type: Series
title: 注文の取込の改善
outline: /abs/path/outline-worktree/tmp/plan.md
branch_prefix: feat/order-import-
timestamp: 2026-01-01T10:00:00+09:00
---

# シリーズ: 注文の取込の改善

## 段

| 段 | リポジトリ | 含むステップ | base | 順序 | worktree | ブランチ | PR |
|----|-----------|-------------|------|------|----------|---------|----|
| A | acme/api | 1・2 | develop | 1 | /abs/wt/api-a | feat/order-import-recv | 12 |
| B | acme/api | 3 | 段 A に積む | 2 | /abs/wt/api-a | | |
| C | acme/web | 4 | main | 3 | | | |

## 強調

| 段 | ノード |
|----|--------|
| A | RECV, VALID |
| B | SAVE |
| C | NOTIFY |

## 全体像

（下の「完成形」を 4 連バッククォートの ````markdown で囲んで置く）

## 進捗

<!-- series-sync status が GitHub から実測して書き換える。手で編集しない -->

## メモ
```

| 節・列 | 書き手 | 変わるとき |
|--------|--------|-----------|
| frontmatter、`## 段` の 段〜順序・worktree、`## 強調`、`## 全体像` | series-init（組み直しも series-init。書き込みは `series_sync.py write` を通す） | 計画の構成が変わったとき |
| `## 段` の ブランチ・PR（worktree が空なら埋める。次の write は下書きの worktree で置き換える） | `series_sync.py register`（create-pr・stack-pr-submit・`/series-sync` から） | PR を作ったとき |
| `## 進捗`、`timestamp` | `series_sync.py status` | 同期のたび |
| `## メモ` | 人 | 任意 |

## 文法

- 段名: `^[A-Za-z0-9][A-Za-z0-9_-]*$`（置換子の中で使うため。描画結果には出ない）
- リポジトリ: `owner/repo`。PR: 数字か空。表のセルに `|` を書かない
- `## 段` の表は、見出しの列名で列を引く（列の並びは問わない）。必要な列は 段・リポジトリ・含むステップ・base・順序・worktree・ブランチ・PR。ほかの列（例: 前提）も置け、register・write は値を書き換えずに残す
- `含むステップ` は横断計画のステップ番号（`### ステップ N:` の N）を `・` で列挙する。範囲（`1-3`・`1〜3`）で書かない（1 語になり、内部 ID の検査を素通りする）
- `## 全体像` の中の最初の ```` ````markdown ```` の行から、次の ```` ```` ```` だけの行までが**完成形**。完成形の最初の空でない行は `## 🗺️ 全体像` で始める
- mermaid のノードは 1 行に 1 つ、行頭で定義する（`RECV["…"]`）。辺の行の中で定義しない（`SRC --> RECV["…"]` は書かない）。check はノードの定義を行頭だけで拾う
- `## 強調` のノードの列はカンマ区切り（前後の空白は無視する）。1 つのノードは 1 つの段にだけ置く。`## 段` のどの段にも 1 つ以上のノードを置く（無い段の PR には黄色が出ず、凡例と食い違う）
- 節の見出しは、コードの囲みの外の `## ` だけを数える（完成形の中の `## 🗺️` は節にならない）

## 完成形と置換子

完成形は、PR ごとに変わる箇所を置換子にしたテンプレート。描画の対象の段を T、その PR を `#N`、リポジトリを R とする。

| 置換子 | 描画 | 未登録の段 |
|--------|------|-----------|
| `{{this}}` | T の `#N` | `（未作成）` |
| `{{pr:S}}` | S が R と同じリポジトリなら `#M`、違えば `owner/repo#M`（GitHub が相互参照のリンクにする） | `（未作成）` |
| `{{num:S}}` | mermaid のラベル用。同じリポジトリなら `#M`、違えば `repo#M`（owner を省く。ラベルはリンクにならない） | `未作成` |
| `{{mark:S}}` | S == T なら `👉`、違えば空 | 同左 |
| `{{prcell:S}}` | S == T なら `**{{pr:S}}**`、違えば `{{pr:S}}` | `（未作成）` |
| `{{classes}}`（行単独。行の字下げを引き継ぐ） | `class <T のノード> cur` と `class <T 以外の段のノード> other` の 2 行。ノードはカンマで空白なしに結合する（`class KEY,PROC cur`）。並びは mermaid の中でノードを定義した順。空の行は出さない | — |

PR ごとに変わるのは置換子の箇所だけなので、同じシリーズの PR のブロックを相互に diff すると、違いは凡例・class の 2 行・表の 2 行（前の 👉 の行と新しい 👉 の行）・別リポジトリの参照の書き方だけになる。

完成形の例:

`````markdown
````markdown
## 🗺️ 全体像（注文の取込の改善）

**この PR（{{this}}）が担う部分を黄色で示しています。** 灰色は同じシリーズの別の PR、点線はシリーズの外です。

```mermaid
flowchart LR
  SRC["取引先のファイル置き場"]
  RECV["{{num:A}} ファイルを受ける<br/>（取引先ごとに分ける）"]
  VALID["{{num:A}} 形式を検証する<br/>（不正な行を隔離）"]
  SAVE["{{num:B}} 注文を保存する<br/>（重複を除く）"]
  NOTIFY["{{num:C}} 取込結果を通知する"]
  SRC --> RECV --> VALID --> SAVE --> NOTIFY
  classDef cur fill:#ffe082,stroke:#f57f17,stroke-width:3px,color:#000
  classDef other fill:#eceff1,stroke:#90a4ae,color:#455a64
  classDef ext fill:#ffffff,stroke:#bdbdbd,stroke-dasharray:4 3,color:#616161
  {{classes}}
  class SRC ext
```

| | PR | リポジトリ | 領域 | 直すもの | 解決する事象 | 順序 |
|---|---|---|---|---|---|---|
| {{mark:A}} | {{prcell:A}} | api | 受付・検証 | … | … | 1 |
| {{mark:B}} | {{prcell:B}} | api | 保存 | … | … | 2（{{pr:A}} に積む） |
| {{mark:C}} | {{prcell:C}} | web | 通知 | … | … | 3 |

- 順序の理由: …
- このシリーズの外: …
````
`````

## PR の本文の目印と置き換え

同期は、本文の中の目印の間だけを書く。区切りの `---` は目印の内側に置き、ブロックを丸ごと置き換え・削除できるようにする。単独の PR の全体像には目印を付けない（目印は同期の持ち物）。

```markdown
ref XX-1234                       ← あれば 1 行目

<!-- series-overview:begin -->
## 🗺️ 全体像（…）
…（完成形を描画したもの）

---
<!-- series-overview:end -->

## 📝 PR 概要 📝
…
```

| 本文の状態 | 既定 | `--migrate` |
|-----------|------|-------------|
| begin と end が 1 組（begin が先） | 目印の間を置き換える（replace） | 同左 |
| 目印が無く、`## 🗺` で始まる見出しも無い | 先頭（1 行目が `ref ` で始まれば、その行と空行の後）に足す（insert） | 同左 |
| 目印が無く、`## 🗺` で始まる見出しがある | **error（書き換えない）** | 見出しから、その後で最初の `---` だけの行までを置き換える（migrate）。その間に別の `## ` 見出しがあるか、`---` が無ければ error |
| 目印が 1 組でない（片方だけ・2 組以上・順序が逆） | error | error |

- 目印の外はバイト単位で変えない。もう一度当てても同じ本文になる（冪等）
- 本文が空（GitHub の REST は `"body": null` を返す）なら空文字として扱い、insert にする
- 見出しの判定は `## 🗺`（U+1F5FA）までの前方一致にする（異体字セレクタ U+FE0F の有無に依らない）
- 本文に CRLF が 1 つでもあれば、足すブロックと区切りの空行を CRLF にする。目印の外の行は、行ごとに元の行末のまま（LF と CRLF が混ざった本文でも変えない）
- 目印と見出しは、本文のコードの囲みの外の行だけを数える（囲みの中に目印の例を書いた本文を壊さない）。本文の終わりまで閉じていない囲みがあれば、すべての行を数える（囲みの後ろの既存のブロックを見落として 2 つ目を足さないため）
- 置き換えた結果が 65,536 字を超えたら error（GitHub の本文の上限）

error の理由の文言（`plan` が PR ごとに出す。同期の手順は `heading-only:` のときだけ `--migrate` を提案する）:

| 理由 | 文言 |
|------|------|
| 見出しだけ | `heading-only: 目印の無い全体像がある。--migrate で置き換えられる` |
| 目印の不整合 | `markers: 目印が 1 組でない（手で直す）` |
| `--migrate` で置き換えられない | `migrate: 全体像の見出しの後に --- の行が無いか、間に別の ## 見出しがある` |
| 上限を超える | `too-long: 置き換えた本文が 65536 字を超える` |
| GitHub の読み取りの失敗 | `gh: …` |

## check が検査すること

1 行 1 件の `error: …` で出し、1 件でもあれば exit 1。`render`・`plan`・`write`（下書きに対して）も先に同じ検査を行う。

- frontmatter に `outline` がある
- `## 段` の表があり、必要な列がそろう。段名の文法・重複、リポジトリが `owner/repo`、PR が数字か空
- `## 進捗` の節がある（`status` が書く先）
- `## 全体像` に完成形の囲みがある。完成形の最初の行が `## 🗺` で始まる
- 完成形に目印の文字列（`series-overview:`）が無い
- `{{classes}}` だけの行がちょうど 1 つで、行の途中には無い
- 引数のファイルが無ければ `error:` で exit 1（`write` の series.md は初回に無いのが正常なので除く）
- 置換子が既知のもので、存在する段を指す
- どの段にも `{{mark:S}}` がある（表に載らない PR を作らない）
- `## 強調` の段が `## 段` にあり、ノードが mermaid の行頭で定義されている。1 つのノードが 2 つの段に無い。`## 段` のどの段にも `## 強調` のノードが 1 つ以上ある
- 完成形に計画の内部 ID が無い。レビュアーは計画を見られないため。`含むステップ` の語のうち、`[A-Za-z]+-?[0-9]+[a-z]?` に当たる語はその語を、数字だけの語 N は `ステップ N`（間の空白は任意）を探す（数字だけでは PR 番号や順序に当たるので探さない）

## 書き込みの規則

series.md を書く口は 3 つだけで、どれも `<series.md>.lock` を `fcntl.flock` で取り、その中で今の series.md を読み直し、自分の持ち分だけを書き換えて、同じディレクトリの一時ファイル＋`os.replace` で置き換える（ロックを取らない読み手の check・render・plan が書きかけを読まないため）。

| 口 | 持ち分 | 呼ぶもの |
|----|--------|---------|
| `register` | `## 段` の 1 行のブランチ・PR（worktree が空なら埋める） | create-pr・stack-pr-submit・`/series-sync` |
| `write` | series.md 全体（ただし運用の値は引き継ぐ） | series-init だけ |
| `status` | `## 進捗` と `timestamp` | `/series-sync`・同期の手順 |

- 人の手編集（`## メモ`）はロックの外になる。同期の実行中に series.md を手で編集しない（コードでは守れない。残るリスク）
- `write` は下書き F を check に通してから、ロックの中で次を行う:
  - 今の series.md が無い（初回）: F をそのまま書く（ロックファイルは作られる）
  - F の `## 段` の各行のブランチ・PR が空なら、今の値を段名で引き継ぐ。`## 進捗`・`## メモ` も今の内容を引き継ぐ
  - worktree は引き継がず、F の値を書く（空なら空にする。worktree 列は series-init の持ち分で、series-init は既存の worktree を毎回見つけ直して F に書く）。series-init が確認した後に register が埋めた worktree は消える。worktree は register の段の絞り込みにしか使わないので許容する（残るリスク）
  - F のブランチ・PR が空でなく、今の値と違う: 書かずに exit 3（下書きに写した古い値で今の登録を上書きしないため。series-init は下書きのこの 2 列を空にする）
  - 段のリポジトリが変わり、今の行に PR が登録済み: 書かずに exit 3（別のリポジトリの同じ番号の PR を書き換えないため。段を外すか、名前を変えて `--drop` する）
  - F に無い段に PR が登録済み: その段が `--drop` にあれば外して `dropped:` に出す。無ければ書かずに exit 3（確認の後に別の worktree が登録した段を、気づかずに消さないため）
  - 外した PR の本文には古いブロックが残る。ブランチ名が `branch_prefix` に当たれば、`status` が以後「未登録」の warning を出し続ける（残るリスク）
- `register` の段の決め方（`--stage` が無いとき）: ① リポジトリが一致し、ブランチ列が `--branch` か PR 列が `--pr` の行 → 無ければ ② リポジトリが一致し PR が空の行。`--worktree` が一致する行があればそれに絞る。1 行に決まらなければ exit 3 で候補を出す（0 行なら「候補なし」）。決まった行の PR が別の番号、またはブランチが別の名前で埋まっていても exit 3（衝突）。同じリポジトリの別の段に同じ PR が登録済みでも exit 3
- `register` は表を壊す値を受け付けない: `--branch` が空（空白だけを含む。detached HEAD で空になり、ブランチ列が空の段すべてに当たるため）、`--branch`・`--worktree` に `|` か改行がある、`--repo` が `owner/repo` でない → exit 1

## 各 worktree への引き継ぎ

series-init は、各リポジトリの worktree の `tmp/context.md` に次を書く（worktree が無い段は `tmp/handoff/<repo>.md` に同じ内容を置く）。

```markdown
---
title: 注文の取込の改善 — api（段 A・B）
base_commit: <worktree の HEAD>
series: /abs/path/outline-worktree/tmp/series.md
outline: /abs/path/outline-worktree/tmp/plan.md
---

# 注文の取込の改善 — api

## シリーズでの担当

| 段 | 含むステップ | base | 順序 | 前提 |
|----|-------------|------|------|------|
| A | 1・2 | develop | 1 | — |
| B | 3 | 段 A に積む | 2 | 段 A が本番に出ている |

- 横断計画の該当ステップは `outline:` の計画を直接読む（写しを置かない。写しは古くなる）
- この worktree で作った PR は、`/create-pr`（スタックなら `/stack-pr-submit`）が `series.md` に登録して全体像を同期する
```

- `series:` があれば、create-pr・stack-pr-submit はシリーズの PR として扱う（本文に全体像を入れず、作った後に登録と同期を行う）
- `outline:` があれば、design は横断計画を読み、この worktree の段の範囲で計画を立てる
- 既存の context.md への追記は、既存の frontmatter に `series:`・`outline:` を足し（無ければ frontmatter を先頭に作る）、末尾に `## シリーズでの担当` を足す。`mode:` などの既存のキーは触らない
- この 2 キーは series-init だけが書く（`/brief` のテンプレートには無い）

## 例の書き方

本リポジトリは公開されている。例は汎用の名前（`acme/api` など）で書き、実際のチケット ID・社名・製品名を書かない。
