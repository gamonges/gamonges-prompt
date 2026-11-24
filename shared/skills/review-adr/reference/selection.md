# 扉の仕分けと観点の選択

`review-adr` の Phase 2 の手順。仕分けの結果・当たった基準・選んだ観点と理由は、すべて `unified.md` に書く（同じ ADR を走らせ直したときに、割れた判断を見つけられるように）。

## 扉の仕分け

`_target.md` に次の基準を上から当てる。1 つでも当たれば**一方向の扉**。

| # | 一方向の扉の基準 |
|---|---|
| (a) | 保存されたデータ・形式を変え、戻すのに移行が要る |
| (b) | 他チーム・外部が依存する契約（API・イベント・鍵・権限）を変える |
| (c) | 不変条件・セキュリティの境界を足す・緩める |
| (d) | 戻すのに複数のチーム・複数のリリースの調整が要る |
| (e) | 外部の契約・ベンダーへの固定 |

- どれにも当たらなければ**双方向の扉**
- **判定できない（材料が足りない）ときは一方向に倒す**（軽い手順で重い判断を通すより、重い手順を 1 回多く回す方が安い）
- 当たった基準ごとに、ADR の該当箇所（節名と引用の一部）を控える

`--depth full` は一方向、`--depth light` は双方向として扱い、`unified.md` に「深さ: <full | light>（引数で上書き）」と書く。引数が無ければ「深さ: <full | light>（仕分け: <一方向 | 双方向>の扉、基準 <(a)…>）」と書く。

## 新しい 5 観点

| 深さ | 走らせる観点 |
|---|---|
| full（一方向の扉） | `adr-decision-quality`・`fact-check`・`adr-premortem`・`rollout-check`・`adr-lineage` |
| light（双方向の扉） | `adr-decision-quality`・`fact-check` |

## 既存の観点

深さに依らず、ADR の中身で選ぶ（可逆な判断でも、暗号の ADR にはセキュリティの観点が要るため）。

| 観点 | 選ぶ条件 | 起動の仕方 | 観点の資料 |
|---|---|---|---|
| `adr` の自己レビュー（`SR`） | 毎回 | `adr-lens-reviewer` | `<skills>/adr/reference/adr-authoring-guide.md` の「5. 自己レビューのチェックリスト」と、`<skills>/adr/reference/cross-check.md` の手順 2・3 |
| セキュリティ（`SA`） | 下の語の表の「セキュリティ」の行が当たる | 下の「起動の仕方」で決める（共有の `security-auditor` は直接起動に当たる） | `security-auditor` の定義 |
| 結合（`CP`） | 「結合」の行が当たる | `adr-lens-reviewer` | `<skills>/coupling-anatomy/SKILL.md` |
| DDD（`DD`） | 「DDD」の行が当たる | 下の「起動の仕方」で決める（`ddd-expert` は共有版も書き込みの道具を持つので資料として渡す） | `ddd-expert` の定義 |

`<skills>` は本スキルの base directory を `realpath` で実体パスにした親（`<実体パス>/..`）。共有のエージェントの定義は `<skills>/../agents/` の下を Glob（`**/<name>.md`）で探す。自己レビューの依頼文には「元資料は対象 repo の実コードとして読む。出典表（`tmp/adr-sources.md`）は作らない」を補足として添える。

### 語の表

ADR のタグ（`_target.md` の「元の属性」）と本文に、行の語が 1 つでも出れば、その行が当たる。大文字小文字は区別しない。

| 行 | 語 |
|---|---|
| セキュリティ | 認可・認証・権限・暗号・鍵・KMS・復号・テナント・PII・個人情報・機密・Security・Auth・OAuth・Compliance・Compliace |
| 結合 | 依存・結合・境界・パッケージ・モジュール・レイヤー・coupling・Architecture |
| DDD | 集約・ドメインイベント・境界づけられたコンテキスト・ユビキタス言語・値オブジェクト・エンティティ・domain modeling |

## プロジェクト固有の観点

対象 repo の `.claude/skills/*/SKILL.md`・`.claude/agents/**/*.md`・`.claude/rules/**/*.md` を、description と ADR に共通して出る語の数で採点して選ぶ。採点は決定的にするためスクリプトで行う（モデルが 100 本近い description の語を数えると、走らせるたびに割れるため）:

```bash
python3 <本スキルの実体パス>/scripts/select_lenses.py <対象 repo> <対象 repo>/tmp/adr-review/_target.md
```

出力は 1 行 1 候補の TSV（得点・出現回数の合計・パス・`selected | dropped | below`・当たった語）で、選ぶ順に並ぶ。スクリプトが持つ規則:

1. 本スキル群自身の名前（`review-adr`・`adr-decision-quality`・`fact-check`・`adr-premortem`・`rollout-check`・`adr-lineage`・`adr-lens-reviewer`）は除く（試しのために対象 repo に一時的に置かれることがあるため）。上の「既存の観点」の表にある共有の観点と同じ名前（`adr`・`security-auditor`・`coupling-anatomy`・`ddd-expert`）も採点しない（下の 4 で扱う。表に行を足したら `scripts/select_lenses.py` の `EXCLUDE` にも足す）
2. 候補: skills・agents は `description` に「レビュー」「review」「点検」「監査」のどれかを含むものだけ（実装の手順を書いた一般の開発スキルは観点ではないため）。rules はこの絞り込みをしない（ルールは規約そのもので、観点の資料になるため）。frontmatter・`description` の無いファイルは候補にしない
3. 得点: `description` から英字で始まる 3 文字以上の英数字列・カタカナ 3 文字以上・漢字 3 文字以上の連なりを語として取り、走査した description のうち 4 本以上に出る語と固定の除外語（「レビュー」「スキル」「ガイド」「ルール」「adr」「code」など）を外し、`_target.md` から frontmatter と「- 入力:」の行を除いた部分に出る語の種類の数を得点にする。2 文字の漢字（「対象」「直接」など）と多くの description に出る語は一般語で、どの ADR にも当たるので数えない。frontmatter と「入力:」の行は入力のパスを含み、パスの語が部分一致で当たるので除く。対象 repo の名前（origin の URL の末尾。無ければ共有の `.git` の親の名前）に部分一致で含まれる語も数えない（製品名は repo の名前にも description にも ADR にも出て、話題と関係なく当たるため。worktree の作業ツリーの名前はブランチ名なので使わない）
4. 共有の観点（上の「既存の観点」の表の `adr`・`security-auditor`・`coupling-anatomy`・`ddd-expert`）と同じ名前の定義がプロジェクトにあれば、プロジェクトの定義を採り、共有の方は選ばない（同じ観点を 2 本走らせない）。この規則はスクリプトの採点に依らず当てる（同名の定義は、既存の観点として選ばれた共有の観点の置き換えなので）
5. 選ぶのは得点 2 以上だけ（1 語だけの一致は偶然とみなす）で、**最大 5 本**（4 で共有の観点を置き換えた定義は数えない）。並びは得点の高い順、同点なら当たった語の出現回数の合計が多い順（ADR がその話題に紙面を割いているほど上）、それも同じならパスの辞書順。上限で落ちたもの（`dropped`）は、名前と理由（「上限で落とした（得点 n）」）を `unified.md` の観点の状態の表に残す。`below` は残さない
6. 表に無い観点には、選んだ順に略号 `PA`・`PB`・`PC`…を振る。プロジェクトの定義で共有の観点を置き換えたときは、共有の観点の略号（`SA`・`DD`）を使う

選んだ理由として、得点と当たった語を 1 行ずつ控える（`unified.md` の「選んだ理由」の列に「得点 n（語・語）」で書く）。

スクリプトが 0 以外で終わった・出力が読めないときは、プロジェクト固有の観点を選ばずに続け、`unified.md` の観点の状態の表に「プロジェクト固有の観点」の 1 行を状態 `失敗`（「select_lenses.py が rc=N」）で残す。総合判定の規則 3 に数える（上限で落としたものと違い、プロジェクトの規約を見たかどうかが分からないため）。

## 起動の仕方

エージェントの定義（共有・プロジェクト）は、次の 2 つを両方満たすときだけ直接起動する。それ以外は、定義のファイルを観点の資料として `adr-lens-reviewer` に渡す。

1. frontmatter に `tools` があり、`Write`・`Edit`・`MultiEdit`・`NotebookEdit` のどれも無い（`tools` が無い定義は全ツールを継承するので当たらない）
2. 同じ名前の定義が、共有とプロジェクトの片方にしか無い（両方にあると、名前でどちらが起動するかに判定が依ってしまうため）

スキル（共有・プロジェクト）は常に資料として `adr-lens-reviewer` に渡す（Skill ツールで呼ばない。観点の実行役を読み取り専用に保つため）。

ルール（`.claude/rules/*.md`）は、`selected` になったものだけを 1 本ずつ個別の観点として、そのファイルを資料にして `adr-lens-reviewer` に渡す（直接起動しない）。`dropped`・`below` のルールは渡さない（`adr-lens-reviewer` は渡された資料をすべて 1 つの観点として当てるので、選ばれていないルールを混ぜない）。
