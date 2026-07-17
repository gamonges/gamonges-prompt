---
name: coupling-plan-diff
description: 実装計画(plan.md)とgit diffを対象に、実装前後で結合構造がどう変化したかをBefore(plan=意図)/After(diff=事実)で分析する。新規実装が結合バランスを改善/悪化させたかの事実ベース把握、`/implement` 後の振り返り、`/coupling-plan-diff` 呼び出しで使用。
---

実装計画(plan.md)と実際のコード差分(git diff)を対象に、実装前後で結合構造がどう変化したかを Before(plan=意図) / After(diff=事実) で分析する。`coupling-anatomy` の3軸（統合強度×距離×変動性）を判定基準として用いる。

**重要**: ソースコードは一切変更しない。デフォルト出力は `./tmp/coupling-plan-diff.md` のみ。
**規約**: CLAUDE.md の Skills 共通規約に従う

判定基準・訳語・出力フォーマットは `coupling-anatomy` スキルを参照する（本スキルでは再宣言しない）。

## パラメーター

- `--plan <path>`: 対象の実装計画ファイル（デフォルト `./tmp/plan.md`）
- diff 範囲: `git diff`（staged + unstaged）を対象とし、それが空なら `git diff HEAD~1`（直近コミット）にフォールバックする（`code-comments` と同じ cascading デフォルト）
- `--artifact`: HTML artifact 生成を行う（デフォルト off）。日常利用（実装後の軽量な事実ベース確認）の頻度が PdM/SRE 共有目的の可視化より高いと想定されるため、opt-in とする

## ワークフロー上の位置付け

| 前工程 | 本コマンド | 後工程 |
|--------|-----------|--------|
| `/design` 計画作成 + `/implement` 実コード変更 | `/coupling-plan-diff` Before/After分析 | （任意）PdM/SRE共有のためのartifact化 |

## 実行条件

`--plan`（省略時 `./tmp/plan.md`）が存在しない場合、即時停止はせず、Before側（plan記載の意図）を省略し、diffから特定した After側（事実）のみで結合関係テーブル・総合判定ブロックを出力する（レポート冒頭にBefore省略の旨を明記する）。git diff・diff HEAD~1 が両方とも空の場合は比較対象がないため停止し、ユーザーに報告する。

## 実行プロセス

### フェーズ1: 入力の読み込み

- [ ] `--plan` で指定された plan.md（省略時 `./tmp/plan.md`）を読み込む。存在しない場合は実行条件に従い Before 側を省略する
- [ ] `git diff --stat` / `git status` で実際のコード変更を確認する

### フェーズ2: plan記載とdiffの乖離チェック（plan.md が存在する場合のみ）

- [ ] `coupling-anatomy` の事実/推測方針に従い、plan.md 記載の意図と実際の diff を突き合わせる。plan=意図・diff=事実であり、両者が食い違う場合は事実（diff）を優先する

### フェーズ3: モジュール見取り図の作成

- [ ] 変更対象をアーキテクチャ層でグルーピングし、NEW / MOD / 既存流用のバッジを付けて見取り図を作る

### フェーズ4: 結合関係のBefore/After判定

- [ ] 主要な結合関係を **10件程度に厳選**し、`coupling-anatomy` の標準フォーマット（**事実ベース変種**: フルクラス名必須、根拠は `file:L{number}`）で Before(plan記載) / After(diff実測) を判定する
- [ ] grep/read で実クラス名・メソッド名の実在を確認してから可視化に使う

### フェーズ5: レポート出力

`./tmp/coupling-plan-diff.md` に見取り図 + Before/After結合関係テーブル + 総合判定ブロックを出力する。

### フェーズ6: artifact生成（`--artifact` 指定時のみ）

- [ ] `coupling-anatomy/reference/artifact-procedure.md` の手順に従う
- [ ] `artifact-design`、`dataviz` スキルを **Skillツールで明示ロードしてから作業する**（暗黙知で代用しない）

### フェーズ7: 完了報告

- Before/Afterで確認した結合関係の件数と、改善/悪化した件数の概要
- `--artifact` 未指定の場合: 「HTML化しますか?」と尋ね、Yesなら `/coupling-plan-diff --artifact` の再実行を案内する（自動連鎖はしない）
