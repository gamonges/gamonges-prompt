---
name: series-init
description: LGTM 済みの横断計画の段の表から、シリーズの契約 tmp/series.md を作り、各リポジトリの worktree を用意して引き継ぎを書く。`/series-init` で使用。
disable-model-invocation: true
---

> **`/series-init` と明示して起動する。** 自然言語からは起動しない。

1 つの対応を複数の PR に分ける（シリーズ）とき、横断計画の `## PR の段` から、シリーズの構成と全体像の完成形を持つ契約ファイル `series.md` を作り、各リポジトリの worktree に引き継ぎ（`tmp/context.md`）を書く。以後、各 worktree の `/create-pr` が PR を series.md に登録し、全 PR の本文の全体像を同期する。

## 補助ドキュメントへの参照

**必ず読む**:

| 補助ドキュメント | 読むタイミング |
|------------------|----------------|
| `../series-sync/reference/series-format.md` | 起動したら最初に（series.md の契約・書き込みの規則・引き継ぎの形の正典） |
| `../create-pr/reference/pr-description-template.md` の「全体像ブロック」 | 手順 3 で完成形を組む時（見た目の語彙の正典） |
| `../series-sync/SKILL.md` の「スクリプトの I/F」 | 手順 4 でスクリプトを呼ぶ時 |

## パラメーター

`series-init [<横断計画>]` — 横断計画のパス。指定が無ければ `./tmp/plan.md`。series.md はその隣（同じディレクトリの `series.md`）に作る。

## ワークフロー上の位置付け

```
/design（## PR の段 を書く）→ /plan-lgtm → /series-init → 各 worktree で /design（outline: を読む）→ /implement → … → /create-pr（登録と同期）
```

## 実行条件

- 横断計画の H1 が `# 実装計画` で始まり、`## PR の段` の表がある。無ければ止めて、`/revise`（既存の計画に段を足す）か `/design` を案内する
- LGTM を plan-lgtm と同じ 3 点で確かめる: `./tmp/plan-review.md` に `**総合判定**: LGTM` がある・その `**対象**:` が今回の計画・plan-review.md が計画より新しい。満たさなければ理由を見せ、続けるかキャンセルかを尋ねる（止めはしない。別の形でレビューした場合があるため）

`$SYNC` は `python3 ~/.claude/skills/series-sync/scripts/series_sync.py`（`$SYNC` は本文の略記。実行するときは毎回展開して書く。シェル変数に入れて `$SYNC check …` とすると、zsh では引数に分かれずに失敗する）、`$S` は作る series.md のパス。

## 手順

### 1. 既存の series.md の確認

- 無ければ新規に作る
- あれば「組み直す（段の表のブランチ・PR と、`## 進捗`・`## メモ`・`timestamp` を段名で引き継ぐ。リポジトリを変えた段のブランチは引き継がない。worktree は手順 2 で見つけ直して下書きに書く。引き継ぎは手順 4 の `write` が行う）／キャンセル」を確認する
- 組み直しで、計画から消えた段（名前を変えた段の旧名を含む）に PR が登録済みなら、組み直す前にその PR を見せ、段ごとに「段を残す（下書きに含める）／段を外す（手順 4 で `--drop` に渡す）／キャンセル」を **1 回の質問**で尋ねる
  - 名前を変えた段は「外す」を選び、組み直しの後に新しい名前へ `$SYNC register "$S" --stage <新しい段名> …` で登録し直す
  - 外した PR の本文には古いブロックが残り、`status` の warning が続くことを、ここで伝える

### 2. 段の解決と worktree の提案

1. 段のリポジトリ名を `owner/repo` にする（作業用 clone の `git -C <作業用 clone> remote get-url origin` から。決まらなければ尋ねる）
2. 作業用 clone ごとに `git -C <作業用 clone> fetch origin` を 1 回行い、既存の worktree を `git -C <作業用 clone> worktree list --porcelain` で探して、段との対応と `branch_prefix`（既存のブランチの共通の接頭辞）を提案する。接頭辞が決まらなければ、3 の前に 1 回だけ尋ねる（作るブランチの名前が接頭辞に依存するため）
3. worktree の無い段には、新しく作る worktree を次の規則で提案する（作るのは手順 6）:
   - 同じリポジトリで worktree の無い段は、まとめて 1 つの worktree にする（スタックの段は 1 つの worktree で積む）。ユーザーは確認で分けられる
   - 名前は `<branch_prefix の / を - にしたもの><先頭の段名の小文字>`、ブランチは `<branch_prefix><先頭の段名の小文字>`（`branch_prefix` が複数なら 1 つ目）、base はその先頭の段の base
   - パスは手順 6 で実際に使う経路で決める:
     - **orca の経路**（`orca` があり、作業用 clone のパスが `orca repo list --json` の `path` に一致する）: `<Orca の workspaces>/<その repo の displayName>/<名前>`。Orca の workspaces は同じ repo の既存の worktree の親の親（既存が無ければ尋ねる）
     - **git の経路**: 同じ作業用 clone の既存の worktree と同じ親ディレクトリの `<名前>`。作業用 clone 自身は数えない。親が複数あれば worktree の数がいちばん多い親にする（同数なら尋ねる）。既存が無ければ尋ねる
4. **作らない段**（handoff に回す。手順 8）を決める。判定は 3 でまとめた worktree 単位で、先頭の段の base・作るブランチ・パスに当てる（スタックの上段の base は下の段のブランチなので、段ごとに当てると上段だけが handoff に回ってしまう）:
   - base のブランチが `origin` に無い（先頭の段そのものが、まだ無いブランチに積む段など）
   - 作るブランチと同じ名前のブランチが、手元か `origin` に既にある段
   - 作る先のパスが既にある段
5. 確認は既存の worktree との対応と合わせて **1 回で行う**。作る worktree はパス・ブランチ・base を、作らない段は理由を見せる
   - ユーザーは段を**対象外**にできる（worktree も handoff も作らない。マージ済みで worktree を消した段など、もう作業しない段のため）。series-init は PR の有無から作業の要否を判断しない

### 3. 完成形を組む

横断計画の概要・ステップ依存関係・`## PR の段`・業務シナリオの割り当てから、処理の流れの段をノードにして完成形を組み、`## 強調` を決める。`## 強調` には、対象外にした段も含めてどの段にも 1 つ以上のノードを置く（無い段の PR には黄色が出ない。`check` が止める）。

- 見た目は「全体像ブロック」の語彙に従う。PR 番号は置換子（`{{num:S}}`・`{{prcell:S}}` など）で書く
- 計画の内部 ID（段名・ステップ ID・`ステップ N`）を完成形に書かない。レビュアーは計画を見られない（`check` が `含むステップ` の ID を検出する）
- ノードは 1 行に 1 つ、行頭で定義する（`check` は行頭の定義だけを拾う）

### 4. 下書き → check → write

1. 組んだ内容を下書き `./tmp/series.draft.md` に Write する。`## 段` のブランチ・PR の列は**空にする**（今の値は write が引き継ぐ。下書きに値を写すと、古い値で今の登録を上書きしうるため write が exit 3 で止める）。worktree の列には手順 2 で確認したパス（既存の worktree、または手順 6 で作るパス）を書く（worktree 列は series-init の持ち分で、`register --worktree` が段を絞るのに使う）。対象外にした段と handoff に回す段は空にする（write は worktree を引き継がないので、空がそのまま書かれる）。手順 6 で作れなかった段の列には作らなかったパスが残るが、`register --worktree` の絞り込みに当たらないだけで害は無い（直すなら手順 4 をやり直す）
2. `$SYNC check ./tmp/series.draft.md`。通らなければ下書きを直す。直しても 3 巡で通らなければ、残る `error:` を報告して止める
3. `$SYNC write "$S" --from ./tmp/series.draft.md [--drop <手順 1 で外すと決めた段> …]` で書く
   - **series.md を Write・Edit で直接書かない。** 同時に走る別の worktree の `register` の登録を消すため。ブランチ・PR・`## 進捗`・`## メモ`・`timestamp` の引き継ぎも write がロックの中で行う（規則は series-format.md の「書き込みの規則」）
   - exit 1 で `error: 今の series.md: …` が出たら、下書きではなく今の series.md の表が壊れている。その行を報告して止める（series.md を直してから再実行する）
   - exit 3 の原因は 4 つ: 手順 1 の後に別の worktree が登録した段が下書きにも `--drop` にも無い／下書きのブランチ・PR が今の値と違う（1 の空にする指示が守られていない）／PR が登録済みの段のリポジトリを変えた／引き継いだ後に同じ PR が 2 つの段に入る（下書きの PR 列に値がある。これも 1 の指示が守られていない。または今の series.md に既に重複がある）。1 つ目はその段と PR を見せ、手順 1 と同じ 3 択で尋ねて、下書きか `--drop` を直して再実行する。2 つ目と 4 つ目は下書きのその列を空にして再実行する（4 つ目で下書きの PR 列が空なら、今の series.md の重複を `$SYNC check "$S"` で確かめて報告する）。3 つ目は、下書きではその段を新しい段名にし、旧い段名を `--drop` に渡して書いてから、新しい段名へ `register --stage` で登録し直す（下書きに旧い段名が残っていると `--drop` は効かない）。またはリポジトリを戻す
   - `dropped:`・`reset:` が出たら報告に含める（`reset:` はリポジトリを変えた段の古いブランチを外した印。新しいリポジトリで `/create-pr` が登録し直す）
4. 成功したら下書きを消す

### 5. 完成形の確認

`$SYNC render "$S" --stage <段>` を 2 段分（別のリポジトリの段を含める）見せ、完成形を確認してもらう。直しは手順 4 と同じく下書き → check → write で行い、往復は 3 巡まで（3 巡で合意しなければ、残る指摘を報告して止める）。

### 6. worktree を作る

手順 2 で確認した worktree を 1 つずつ作る。順序は「orca → orca が使えないか、残骸を残さずに失敗したら git → git も失敗したら手順 8 の handoff」。orca が残骸を残して失敗したら git へは進まず handoff に回す。同じ経路の再試行はせず、handoff に回したら次の worktree へ進む。

- **orca の経路**（`orca` があり、repo が Orca に登録されている）:
  1. `orca repo list --json` から作業用 clone のパスが一致する repo id を引く
  2. `orca worktree create --repo id:<id> --name <名前> --base-branch origin/<base> --parent-worktree path:<series-init を実行している worktree の toplevel> --comment "<series の title>（段 <段名…>）" --json` で作る（Orca の親子関係が付く）。`--setup` は渡さない（リポジトリの setup の方針に従う）
  3. `git -C <path> branch -m <ブランチ>` で改名する（Orca はブランチ名を自分の接頭辞で付けるため）。`git -C <path> branch --show-current` が `<ブランチ>` でなければ改名の失敗
  4. `orca worktree show --worktree path:<path> --json` の branch が `refs/heads/<ブランチ>` であることを確かめる。改名の直後は古い名前を返すことがあるので、2 秒おいて最大 3 回見る。3 回とも違えば改名の失敗と同じ扱い
  5. `git -C <path> rev-parse --abbrev-ref @{u}` が成功する（upstream が付いている）なら `git -C <path> branch --unset-upstream` で外す（`origin/<base>` を追跡したままだと、pull・push が base のブランチを向く）。改名に失敗したときも行う
- **orca が失敗したとき**（非 0 で終わる、または `--json` の `ok` が true でない）: git へ進む前に残骸を確かめる
  - `git -C <作業用 clone> worktree list --porcelain` に手順 2 のパスか `--name` の名前で終わるパスがある、または `git -C <作業用 clone> branch --list '*<名前>'` に当たるブランチがある → git へは進まず、その段を handoff に回し、残ったパス・ブランチを報告に書く（消すかはユーザーが決める。series-init は消さない）
  - 残骸が無い → git の経路へ進む
- **git の経路**（`orca` が無い、repo が Orca に登録されていない、または orca が残骸なしで失敗した）: `git -C <作業用 clone> worktree add --no-track -b <ブランチ> <パス> origin/<base>` で作る（`--no-track` の理由は orca の経路の 5 と同じ）
  - パスは手順 2 で見せたもの（orca の経路から落ちてきたときも同じパス。ユーザーが確認したパス以外には作らない）
  - Orca の親子関係は付かないことを報告に書く
  - 失敗したら handoff に回す
- **改名だけが失敗したとき**（同じ名前のブランチが手順 2 の後にできたなど）: worktree は残し、今のブランチ名とエラーを報告に書く。handoff には回さず、context.md は書く（手順 7）

### 7. 各 worktree の context.md

既存の worktree と手順 6 で作った worktree ごとに `tmp/context.md` を書く（形は series-format.md の「各 worktree への引き継ぎ」）。対象外にした段だけを持つ worktree には書かない。

- 既存の context.md があれば「上書き／追記／キャンセル」を確認する（複数あれば 1 回の質問にまとめる）。追記は、既存の frontmatter に `series:`・`outline:` を足し（frontmatter が無ければ先頭に作る）、末尾に `## シリーズでの担当` を足す。`mode:` などの既存のキーは触らない
- 手順 6 で作った worktree には context.md が無いので、確認は要らない

### 8. handoff

手順 2 の「作らない段」と、手順 6 で作れなかった段（対象外にした段は除く）は、リポジトリごとに `./tmp/handoff/<repo>.md` に context.md と同じ内容を置き、worktree を作ったら `tmp/context.md` に置くよう案内する。既存の handoff があれば上書き／キャンセルを確認する。

### 9. 報告

- series.md のパスと、`dropped:` で外した PR、`reset:` で外したブランチ
- 段と worktree の対応。作った worktree は「作成」と書き、`git worktree add` で作ったものは Orca の親子関係が無いことを添える
- 改名に失敗した worktree: パス・今のブランチ名・エラー
- orca が残した残骸: パス・ブランチ（消すかはユーザーが決める）
- 書いた context.md・handoff と、worktree を作らなかった理由（対象外にした段も名指しする）
- 次の手順: 各 worktree の `/design` が `outline:` を読む。PR は各 worktree の `/create-pr`（スタックなら `/stack-pr-submit`）が登録と同期を行う

## 書かないもの

- 横断計画は書き換えない
- 作業用 clone の追跡ファイルに触れない。作業用 clone に足すのは手順 6 のブランチと worktree だけで、ファイルは各 worktree と横断計画の worktree の `tmp/` だけに書く
- Orca の設定（`branchPrefix` など）は変えない
- worktree・ブランチを消さない（残骸も、作った worktree のロールバックも、消すかはユーザーが決める。orca で作ったものは `orca worktree rm`、git で作ったものは `git worktree remove` と `git branch -D`）
