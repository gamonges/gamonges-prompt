# 入力・立場・Notion の読み込み・スナップショット

`review-adr` の Phase 0（入力と立場）と Phase 1（スナップショット）の手順。`adr-lineage` を単独で走らせたときも、Notion の引き方（「番号でページを引く」「参照先の 1 段」）はここに従う（そのときはスナップショットのファイルを作らない）。

Notion は読むだけ（`notion-fetch`・`notion-search`・`notion-get-comments`）。コメントの投稿・ページの編集はしない。

以下の `tmp/adr-review/` は、すべて `<対象 repo>/tmp/adr-review/`（`git rev-parse --show-toplevel` の値から組んだ絶対パス）を指す（相対パスのままだと、サブディレクトリから起動したときに Phase 0 のガードが見た場所と違う場所を作り直すため）。

## Phase 0: 入力の解決

上から順に当て、最初に当たった行で決める。止まる行では `tmp/adr-review/` に触れない（Phase 1 より前に止まるので、前回の結果が残る）。

| 入力 | 既定の立場 | 手順 |
|---|---|---|
| 存在するファイルのパス | `self` | `python3 <本スキルの実体パス>/scripts/input_guard.py <入力> <対象 repo>` を呼ぶ。rc=1（入力が Phase 1 の作り直しで消える場所にある）・rc=2 なら、stderr の 1 行を返して止まる。rc=0 なら `realpath` で実体パスにして進む（判定を手順書で組み直さない。`tmp` が symlink のときに入力を消さないための比較はスクリプトが持つ） |
| `https://` で始まり `notion.` を含む URL | `review` | `notion-fetch` で読む。読めなければ「対象の ADR を読めない（理由）」と 1 行返して止まる |
| `ADR-<番号>`（`^ADR-[0-9]+$`） | `review` | 下の「番号でページを引く」。一意でなければ止まる |
| それ以外（存在しないパスを含む） | — | 「入力がパスでも Notion の URL でも ADR の番号でもない（<入力>）」と 1 行返して止まる |

- 対象の本文（ローカルの md は frontmatter を除いた部分、Notion は `notion-fetch` の本文）が空白だけなら「対象の本文が空」と 1 行返して止まる
- `--as self|review` があれば立場を上書きする
- 採ったページ・ファイルのタイトルを、`unified.md` の「対象」に書く

### 番号でページを引く

ADR の番号はタイトルに入っておらず、ページの属性 `ID`（自動採番。SQL の列名は `"userDefined:ID"`、値は整数）にある。セマンティックな検索（`notion-search`）は完全一致でないので使わず、属性を完全一致で照会する。

1. ADR DB（`../../notion-adr/SKILL.md` の「方法A」にあるデータベース。`collection://` の後ろの ID はデータベースの ID）を `notion-fetch` し、返る `<data-source url="collection://…">` の URL を data source として使う
2. `notion-query-data-sources` の SQL で `SELECT url, "名前", "採用状況" FROM "<data source>" WHERE "userDefined:ID" = ?`（`params` に番号を整数で）を呼ぶ。列名が返らないなどで失敗したら、手順 1 の `<sqlite-table>` の列名で書き直して 1 回だけやり直す
3. 結果が **1 件のときだけ**採り、その `url` を `notion-fetch` する。0 件なら「ADR-<番号> に一致するページが無い」、2 件以上なら候補のタイトルと URL を並べて止まる

どの手順で失敗しても（手順 1 の `notion-fetch` の失敗・`<data-source>` が無い、手順 2 のやり直しの失敗、手順 3 の `notion-fetch` の失敗）、行き先は次のとおり:

- 対象を引いているとき: 立場によらず（`--as self` でも）「対象の ADR を読めない（ADR-<番号>: <失敗した手順と理由>）」と 1 行返して Phase 0 で止まる
- 参照先を引いているとき（下の「参照先の 1 段」）: 止まらず、関係と理由を `_lineage-index.md` に並べて続ける（Phase 4 で `unified.md` の「読めなかった入力」に写す）。`adr-lineage` を単独で走らせたときは、自分の結果の「読んだもの」に書く（スナップショットを作らないため）

## Notion を読めないとき

Notion の MCP が無い・権限が無い・呼び出しが失敗したとき:

- 対象自体が Notion にある（URL・`ADR-<番号>` の入力）→ 立場によらず（`--as self` でも）Phase 0 で止まる（上の表）
- それ以外（ローカルの md）→ `_comments.md` を「取得できなかった（理由）」の 1 行にし（コメントを読む先が無いときは「コメントなし（…）」のまま）、`_lineage-<番号>.md` を作らない。`_lineage-index.md` には、本文から拾った参照先を関係つきで並べ、スナップショットの列を「読めなかった（Notion を読めない）」にする（参照先が無ければ「参照先なし」）。コメントと参照先は、Phase 4 で `unified.md` の「読めなかった入力」に写す。`adr-lineage` は `走らなかった` にせず、残りの材料（対象の属性と本文）で走らせる（判定への効き方は `unified-template.md` の総合判定の 4 で決める。観点の欠けにも数えると、記録だけにする入力の欠けまで full でだけ `直してから出す` になるため）

## Phase 1: スナップショット

`tmp/adr-review/` を確認せず消してから作る（`rm -rf <対象 repo>/tmp/adr-review && mkdir -p <対象 repo>/tmp/adr-review`。`<対象 repo>` は絶対パスで書き込む。実行のたびに作り直す契約で、前回の観点の結果を今回の結果として読まないため）。次の 3 種類を Write する。どれも下の雛形の frontmatter で始める。

### `_target.md`（対象の ADR）

- 「元の属性」の節:
  - ローカルの md: 入力の frontmatter のキーと値を、そのまま箇条書きで写す（`#` で始まるコメントの行は写さない）。frontmatter としては写さない（2 つ目の frontmatter は本文として読まれるため）
  - Notion: `notion-fetch` が返すページの属性（採用状況・日付・タグなど）を写す
- 「本文」の節: ローカルなら frontmatter を除いた本文、Notion なら `notion-fetch` の本文をそのまま
  - Notion の本文は、下の「Notion の本文を要約せずに写す」の手順で作る。`_lineage-*` の参照先の抽出はこの「本文」の節を読むので、`_target.md` を組み立て終えてから参照先に進む

<!-- tmp-frontmatter: tmp/adr-review/_target.md -->
```markdown
---
type: ADR Review
title: 対象の ADR — {ADR のタイトル}
description: review-adr のスナップショット。{入力のパスか URL} の元の属性と本文
status: stable
---
# 対象の ADR — {ADR のタイトル}

## 元の属性

- 入力: {実体パス | URL}
- {キー}: {値}

## 本文

{本文をそのまま}
```

### Notion の本文を要約せずに写す

モデルが `notion-fetch` の結果を Write で写すと、長い本文が要約・抜粋になる（試しで、参照先の ADR が抜粋で写された）。Claude Code の会話の記録には結果がそのまま残るので、`scripts/notion_fetch_body.py` で機械的に取り出す。`_target.md`・`_lineage-<番号>.md` の両方に同じ形で当てる（下の `<名前>` は `_target` か `_lineage-<番号>`）。

1. `date -u +%Y-%m-%dT%H:%M:%SZ` で時刻を控える（取り出しを今回の呼び出しに限るため。過去のセッションの同じページの古い版を、黙って使わない）
2. `notion-fetch` を呼ぶ
3. 次を呼ぶ（`<…>` は値を書き込む。シェル変数に詰めない。`"$CLAUDE_CODE_SESSION_ID"` は Claude Code が渡す 1 語の環境変数をクオートして展開するもので、これには当たらない）:

   ```bash
   python3 <本スキルの実体パス>/scripts/notion_fetch_body.py --page <URL> --session "$CLAUDE_CODE_SESSION_ID" --since <1 の時刻> --out tmp/adr-review/<名前>.body.part --props-out tmp/adr-review/<名前>.props.part
   ```

4. rc=0 なら、`<名前>.props.part`（`<properties>` の中身の JSON）を読み、雛形の frontmatter・見出し・「## 元の属性」の箇条書き・`## 本文` の見出しと空行までを `tmp/adr-review/<名前>.head.part` に Write する。`cat tmp/adr-review/<名前>.head.part tmp/adr-review/<名前>.body.part > tmp/adr-review/<名前>.md` でまとめ、3 つの `.part` を消す（`.md` を Write で書かないので、本文がモデルを通らない）
5. rc=1（今回の結果が記録に無い・セッション ID が空）・rc=2 なら、`notion-fetch` の結果を要約・抜粋せずに Write で写す。写しきれないときは「元の属性」に `写し: 抜粋（<理由>）` を足し、参照先なら `_lineage-index.md` のスナップショットの列にも「抜粋で写した」と書く（Phase 4 で `unified.md` の「読めなかった入力」に、種類は対象本文か参照先、理由は「抜粋で写した」で写す）

スクリプトは今回のセッション（`CLAUDE_CODE_SESSION_ID`）とそのサブエージェントの記録だけを読む（同じ worktree の別のチャットが同じページを開いても、その結果を採らないため）。Codex から走らせたときは、Codex の `notion-fetch` は Claude Code の会話の記録に残らないので rc=1 になり、手順 5 に進む。

### `_comments.md`（対象のコメント）

読む先のページ:

- Notion の入力: そのページ
- ローカルの md: frontmatter の `notion_page` の値が `https://` で始まり `notion.` を含む URL のときだけ、そのページ。キーが無い・`未起票` など URL でない値なら読まない

`notion-get-comments` で読み、次のどれかにする:

- 「コメントなし（Notion のページが無い: notion_page が <値。キーが無ければ「キーなし」>）」の 1 行
- 「コメントなし（ページにコメントが 0 件）」の 1 行
- 「取得できなかった（<理由>）」の 1 行（Phase 4 で `unified.md` の「読めなかった入力」に、種類: コメントで写す）
- スレッドごとの節（下の雛形）

<!-- tmp-frontmatter: tmp/adr-review/_comments.md -->
```markdown
---
type: ADR Review
title: コメント — {ADR のタイトル}
description: review-adr のスナップショット。{スレッド {n} 件 | コメントなし（理由） | 取得できなかった（理由）}
status: stable
---
# コメント — {ADR のタイトル}

- 読んだページ: {URL}

## スレッド 1: {貼られた節か「ページ全体」}

- 解決: {済み | 未解決 | 不明}
- {投稿者}（{日付}）: {本文}
- {返信の投稿者}（{日付}）: {本文}
```

### `_lineage-<番号>.md`（参照先の 1 段）

対象の本文が `ADR-<番号>` を参照・置き換えとして書いている ADR を、1 段だけ読む（参照先がさらに参照する ADR は読まない。同じ題材の ADR の検索もしない）。

1. 対象の本文（`_target.md` の「本文」）から `ADR-[0-9]+` を拾い、対象自身の番号を除く
2. 番号ごとに、本文にその ADR の URL（`https://` で始まり `notion.` を含む）が添えてあればその URL を `notion-fetch` する。番号だけなら Phase 0 の「番号でページを引く」と同じ一意の一致で引く。本文は「Notion の本文を要約せずに写す」の手順で `_lineage-<番号>.md` にする
3. 一意でない・読めない参照先はファイルを作らず、候補（タイトルと URL）か理由を `_lineage-index.md` に並べる（Phase 4 で `unified.md` の「読めなかった入力」に、種類: 参照先（<関係>）で写す）。関係は手順 4 と同じ書き方で、読めなかった参照先にも本文から決める（総合判定が関係で効き方を分けるため）
4. 本文中の関係（置き換える・前提にする・並ぶ・退けた）を 1 行で書く

<!-- tmp-frontmatter: tmp/adr-review/_lineage-{n}.md -->
```markdown
---
type: ADR Review
title: 参照先の ADR — {参照先のタイトル}
description: review-adr のスナップショット。対象が {置き換える | 前提にする | 並ぶ | 退けた} ADR-{番号} の元の属性と本文
status: stable
---
# 参照先の ADR — {参照先のタイトル}

## 元の属性

- URL: {URL}
- 対象との関係: {対象の本文での書き方の引用}
- {属性}: {値}

## 本文

{本文をそのまま}
```

### `_lineage-index.md`（参照先の一覧）

`_lineage-<番号>.md` を書き終えた後に、参照先の一覧を書く。参照先の本文（多いと数十 KB）は `adr-lineage`・`adr-decision-quality`・Codex にだけ渡し、他の観点にはこの一覧だけを渡す（全観点に本文を渡すと重く、受け持ちの外の指摘まで増えるため。`SKILL.md` の Phase 3）。参照先が無ければ「参照先なし」の 1 行にする。読めなかった参照先も、理由つきで並べる。

<!-- tmp-frontmatter: tmp/adr-review/_lineage-index.md -->
```markdown
---
type: ADR Review
title: 参照先の一覧 — {ADR のタイトル}
description: review-adr のスナップショット。対象が参照する ADR {n} 件（読めなかった {n} 件）の一覧
status: stable
---
# 参照先の一覧 — {ADR のタイトル}

| 番号 | タイトル | 対象との関係 | スナップショット |
|---|---|---|---|
| ADR-{番号} | {タイトル} | {置き換える・前提にする・並ぶ・退けた のどれか}（{本文での書き方の引用}） | {_lineage-<番号>.md の絶対パス、または 読めなかった（理由）} |
```
