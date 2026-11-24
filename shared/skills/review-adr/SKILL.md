---
name: review-adr
description: ADR を観点ごとのサブエージェントと Codex で並列にレビューし総合判定を出す。自分の ADR の点検・他人の ADR のレビュー、`/review-adr` で使用。
---

ADR を、観点ごとに独立したサブエージェントと Codex で並列にレビューし、1 つの総合判定にまとめる。本スキルが持つのは観点の選択・受け渡し・集約だけで、観点の中身（問いと判定の基準）は観点ごとのスキルにある。

出力先: `./tmp/adr-review/`（観点ごとの `<観点>.md`・`codex.md`・`unified.md`・スナップショット `_*.md`）。ADR は書き換えず（直すのは人か `/adr`）、Notion にも書かない（コメントは案を書くだけ）。

**前提**: 同じ作業ツリーで `review-adr` を 2 本同時に走らせない。`tmp/adr-review/` は実行のたびに確認せず消して作り直す契約で（`review` の `tmp/review/` と同じ）、`tmp/` の成果物を黙って上書きしない規約の対象外。

## 補助ドキュメントへの参照

**必ず読む**（起動したら必ず通るフェーズで使う）:

| 補助ドキュメント | 読むタイミング |
|------------------|----------------|
| `./reference/sources.md` | Phase 0 で入力を解決する時 / Phase 1 でスナップショットを作る時 |
| `./reference/selection.md` | Phase 2 で扉を仕分け、観点を選ぶ時 |
| `./reference/finding-format.md` | Phase 3 で依頼文を組む時 / Phase 4 で形の不正を判定する時 |
| `./reference/unified-template.md` | Phase 4 で集約し `unified.md` を書く時 |

**条件付きで読む**:

| 補助ドキュメント | 読むタイミング |
|------------------|----------------|
| `./reference/codex.md` | `--no-codex` が無い時（Phase 3 で起動し、Phase 4 で待ち合わせる） |

## 引数

```
/review-adr <ADR のパス | Notion の URL | ADR-<番号>> [--as self|review] [--depth full|light] [--no-codex]
```

- `--as`: 立場の上書き（既定はパスなら `self`、URL・番号なら `review`）
- `--depth`: 扉の仕分けの上書き（`full` は 5 観点、`light` は 2 観点）
- `--no-codex`: Codex を起動しない

引数の誤り（パスが無い・URL が Notion でも ADR の番号でもない・入力が `tmp/adr-review/` の下・番号の一致が一意でない）は、本題に入らず理由を 1 行で返して止まる。止まるときは `tmp/adr-review/` に触れない。

## Phase 0: 入力と立場

`./reference/sources.md` の「Phase 0: 入力の解決」に従う。`<対象 repo>` は `git rev-parse --show-toplevel` の値。

## Phase 1: スナップショット

`./reference/sources.md` の「Phase 1: スナップショット」に従い、`tmp/adr-review/` を作り直して `_target.md`・`_comments.md`・`_lineage-<番号>.md`・`_lineage-index.md` を書く。Notion を読めないときの扱いも同じファイルにある。

## Phase 2: 仕分けと選択

`./reference/selection.md` に従い、扉を仕分け、新しい観点・既存の観点・プロジェクト固有の観点を選び、起動の仕方と略号を決める。

## Phase 3: 起動

選んだ観点を**同じターンで並列に**起動する（観点ごとに独立に評価させ、互いの結論に引きずられないようにするため）。Codex も同じターンで起動する（`./reference/codex.md`）。

パスはすべて絶対パスで渡す（観点の実行役の cwd は対象 repo なので、相対パスは別のファイルを指す）:

- 観点の資料: 本スキルの base directory を `realpath` で実体パスにし、その親から組み立てる（例: `<実体パス>/../adr-decision-quality/SKILL.md`）。新しい 5 観点では、`SKILL.md` と並べて同じ観点の `reference/questions.md` の絶対パスも書く（問いと判定の基準はそこにある。資料の相対参照を実行役が解決するかに頼らないため）
- スナップショット・出力の形: `<対象 repo>/tmp/adr-review/…`、`<実体パス>/reference/finding-format.md`

`adr-lens-reviewer`（新しい観点・自己レビュー・結合・スキルの観点・直接起動しないエージェント）への依頼文:

```text
観点の資料: <絶対パス（複数なら並べる）>
観点の補足: <selection.md が補足を定めた観点だけ。無ければ「なし」>
スナップショット: <_target.md・_comments.md・_lineage-index.md の絶対パス。adr-lineage・adr-decision-quality だけ _lineage-*.md も並べる>
立場: <self | review>
対象 repo: <絶対パス>
出力の形: <finding-format.md の絶対パス>
指摘の ID の略号: <略号>
```

参照先の本文（`_lineage-*.md`）を渡すのは `adr-lineage`・`adr-decision-quality` と Codex だけで、他の観点には一覧の `_lineage-index.md` だけを渡す（参照先が多いと数十 KB になり、全観点に渡すと重く、受け持ちの外の指摘まで増えるため）。

直接起動するエージェント（`selection.md` の「起動の仕方」で直接に当たったもの）には、同じ 7 行に「出力の形は `finding-format.md` に従い、結果は最終メッセージに frontmatter から全文で書く。ファイルは作らない。会話の外の記憶（auto-memory など）は根拠に使わない」を添える（`adr-lens-reviewer` の定義が持つ規則を、定義を変えられない共有・プロジェクトのエージェントには依頼文で渡す）。

親の読み（自分の評価・他の観点の結果）は依頼文に書かない。

## Phase 4: 集約

1. `--no-codex` でなければ、最初に Codex を待ち合わせる（`./reference/codex.md` の「結果の扱い」）。`wait` が時間切れ（3）で返ったら 1 回だけ待ち直し（合計で最大 1140 秒）、それでも終わらなければ未実施として続ける
2. `./reference/unified-template.md` に従い、観点の結果を `tmp/adr-review/<観点>.md` に書き、観点の状態を決め、重複をまとめ、総合判定を決めて `tmp/adr-review/unified.md` を書く
3. 完了報告に、総合判定の行・観点の状態の表・Codex の状態行を写す。HTML 化を 1 回だけ提案する

## してはいけないこと

- ADR（ローカルの md・Notion のページ）を書き換えない
- Notion にコメントを投稿しない・ページを編集しない（読むのは `notion-fetch`・`notion-query-data-sources`・`notion-get-comments` だけ）
- 観点のスキルを Skill ツールで呼ばない（`adr-lens-reviewer` に Read させる）
- 外の系（DB・Datadog など）に書き込まない
- 同じ題材の ADR を検索しない（読むのは本文が参照・置き換える 1 段とコメントだけ）
