---
name: verify-scenario
description: verification.md のシナリオをローカルで実行して実装直後の検証を行う。実装完了後の動作確認、「検証して」「シナリオを回して」のキーワードで使用。
---

## 補助ドキュメントへの参照

**必ず読む**（起動したら必ず通るフェーズで使う）:

| 補助ドキュメント | タイミング |
|------------------|-----------|
| `./reference/verification-format.md` | フェーズ 1 で書式を確認する時 / フェーズ 5 で結果を書き戻す時 |

**条件付きで読む**:

| 補助ドキュメント | 読むタイミング |
|------------------|----------------|
| `claude/skills/playwright-cli/SKILL.md` | フェーズ 3 で UI 操作を自動化する時 |
| `./reference/redash-template.md` | 実行済みの `Side effect:` を本番監視クエリへ写す時（**未実証**。冒頭のマーカーを読んでから使う） |

「念のため全部読む」は禁止。条件付きの表はトリガー条件に該当する場合のみ読み込む。

## パラメーター

`verify-scenario [<capability>[/<scenario-name>]]`

- `<capability>` 省略時: 変更差分（`git diff <デフォルトブランチ>...HEAD`）が触れた capability を特定し、`openspec/specs/<capability>/verification.md` が存在するものを対象にする
- `/<scenario-name>` 省略時: その capability の全 Driving 行を対象にする

## ワークフロー上の位置付け

| 前工程 | 本コマンド | 後工程 |
|--------|-----------|--------|
| `/implement` Phase 4（実装直後） | `verify-scenario` ① の実行 | `/review` → `integration-test-scenario`（② QA 引き渡し前） |

## 実行条件

- 対象 capability に `openspec/specs/<capability>/verification.md` が存在すること。存在しなければ停止し、`/verification-authoring` での骨格生成を案内する
- openspec を持つリポジトリであること（持たない repo では本 skill は対象外）
- 対象アプリケーションのローカル環境が起動していること
- `Preconditions` の seed コマンドが実行可能であること

## 既存 skill との責務境界

| skill | 起点 | 出力 |
|-------|------|------|
| `verify-scenario`（本 skill） | capability の `verification.md` | 実行結果を verification.md の `draft:` 解消として反映 |
| `integration-test-scenario` | PR / diff | `./tmp/integration-test-scenario.md` |
| `integration-test-run` | 上記の手順書 | `./tmp/integration-test-results.md` |

起点が違うので重複起動しない。PR 単位で観点を洗い出す段階なら `integration-test-scenario` を使う。

## 実行プロセス

### フェーズ 1: verification.md を読む

`Preconditions` / `How to get to it` / `Driving it` / `Gotchas` を把握する。`draft:` 行と実行済み行を数え、今回の対象行を確定する。

書式が崩れている場合は先に `node ~/.claude/skills/verify-scenario/scripts/verification-lint.mjs <path>` で検査する（パスは install 後のランタイム位置。skill は対象リポジトリの外から実行されるため、repo 相対では解決できない）。

### フェーズ 2: Preconditions の再現（seed）

`Preconditions` の seed コマンドを実行する。

- **seed のプロセス終了を待ってから次へ進む**。実行中に画面操作すると中間状態を観測してしまう
- **seed が失敗したら「その capability の入口が変わった」回帰検知として報告する**。seed は本番と同じ書込経路（Usecase / CommandHandler）を通るため、失敗は「入口のシグネチャや不変条件が変わった」ことを意味する。単なる環境エラーとして片付けない
- 記録は `— / blocked`。**確度に「環境にデータが無い」を意味する区分を割り当てない** — seed 失敗を環境要因の語彙で記録すると、検知した回帰が報告から消える

### フェーズ 3: 操作（WHEN）

`How to get to it` の経路で `Driving it` の操作を行う。UI 操作の自動化は `playwright-cli` に委譲する。

UI から到達できない場合（管理者専用・cron 起動等）は、該当 Usecase / API を同じ手順で直接実行する。この場合の確度は UI 経由より 1 段低くなる（`report-template.md` の該当区分）。

### フェーズ 4: `Side effect:` の実行と照合

`Side effect:` の SELECT を実行し、actual を取得して expected と照合する。

- **actual は実測値をそのまま記録する**（expected に寄せて丸めない）
- 不一致は fail として報告する。観測結果が一致していても `Side effect:` が不一致なら fail（Read Model 側の疑いが残るため、画面が正しく見えることを合格の根拠にしない）

### フェーズ 5: 判定と記録

判定を `<確度> / <合否>` の 2 軸で記録し、verification.md の該当行を更新する。

- pass した行: actual を転記し `draft:` を外す
- fail した行: actual を転記し `draft:` は外さない（実装 or expected を直してから再実行する）

## 判定は 2 軸

| 軸 | 値 | 定義の場所 |
|----|----|-----------|
| **確度**（どこまで実機に近いか） | 4 区分 | `claude/skills/integration-test-run/reference/report-template.md` に従う（本 skill は区分の定義を複製しない） |
| **合否**（期待と一致したか） | pass / fail / blocked / draft | 本 skill 固有 |

記録形式は `<確度> / <合否>`（例: `実機live / fail`）。

**確度は確認が成立した場合にのみ付く。** seed 失敗・未実行のように確認そのものが成立しなかった場合は確度を `—` にし、合否だけで表現する。ここを埋めようとすると環境要因の区分を誤って割り当てることになり、検知した回帰が報告から消える。

## 完了パスツリー

```
verify(<capability>/<scenario>)
├── seed 成功
│   ├── 操作成功（UI 到達可能）
│   │   ├── 観測結果 一致 + Side effect 一致   → 実機live / pass
│   │   ├── 観測結果 一致 + Side effect 不一致 → 実機live / fail   （Read Model 側の疑い）
│   │   └── 観測結果 不一致                    → 実機live / fail   （実装 or expected の誤り）
│   └── UI から到達不能（管理者専用・cron 起動等）
│       └── 該当 Usecase / API を同じ手順で直接実行
│           ├── 一致   → 実API再現 / pass
│           └── 不一致 → 実API再現 / fail
├── seed 失敗（Usecase の入口が変わった）
│   └── — / blocked   ← 確度は付けない（確認が成立していない）
└── 未実行
    └── — / draft     ← 完了として扱わない
```

区分名は判定結果として使うだけで、証拠の定義は `report-template.md` 側にある。

## 反復

- **開始トリガー**: 実装を変更した直後、または verification.md に `draft:` 行がある時
- **反復トリガー**: fail に対して実装または expected を修正した後（修正した行を再実行する）
- **完了条件**: 対象の Driving 行が `draft:` 0 行かつ fail 0 件
- **打ち切り**: 3 巡して収束しない場合は中断し、残る fail 行と収束しない理由（実装の問題か expected の誤りか切り分けられない等）を報告する。**打ち切りは完了ではない**

## 注意事項

- **`draft:` が残る状態を「検証済み」として報告しない。** 未実行の行は成果物ではなく下書き
- 本 skill と `reference/` には capability 名・テーブル名・URL・組織 ID を書かない（本リポジトリは PUBLIC）。具体値は対象リポジトリの verification.md にのみ置く
- 実行済みの Driving 行が揃ったら、`/verification-authoring` の逆流で spec.md の Scenario を起こせる
