---
name: fix-lgtm-implement
description: fix で修正計画を作成し、review-plan と revise を LGTM になるまで自動で繰り返し、最後に implement で実装まで一気通貫実行する。PR レビュー指摘の取り込みから修正実装完了までの自動化、`/fix-lgtm-implement` 呼び出しで使用。
---

`fix → LGTM ループ → implement` を 1 コマンドで一気通貫実行する。`fix` で修正計画を作成し、`plan-lgtm` でその計画を `LGTM` になるまで自動修正し、`LGTM` に到達した場合のみ `implement` で実装を完了する。

**重要**: 本スキル自体はソースコードを変更しない。内部で呼び出す `fix`/`plan-lgtm`/`implement` がそれぞれの副作用（`./tmp/fix-plan.md` の生成・更新、ソースコードの変更）を行う。
**規約**: CLAUDE.md の Skills 共通規約に従う

## パラメーター

`$ARGUMENTS` は `fix` にそのまま引き継ぐ。PR の URL/番号、または `fixes.md` 等のローカルファイルパス。省略時は `fix` の既定（`./tmp/fixes.md`）に従う。

## ワークフロー上の位置付け

| 前工程 | 本コマンド | 後工程 |
|--------|-----------|--------|
| `/implement` 実装完了 + `/review` or PR レビュー | `/fix-lgtm-implement` 修正計画作成〜実装完了の一気通貫実行 | `/spec-propose` or `/create-pr` |

## 実行条件

`fix` の実行条件（`./tmp/fixes.md`、PR URL/番号、または `./tmp/review/unified.md` のいずれか）を継承する。個別に再定義しない。条件を満たさない場合、`fix` 自体が停止するため本スキルもそこで停止する。

## 実行プロセス

### フェーズ 1: 修正計画の作成

`Skill` ツールで `fix`（`$ARGUMENTS` をそのまま渡す）を呼び出し、`./tmp/fix-plan.md` を生成させる。

### フェーズ 2: LGTM ループ

`Skill` ツールで `plan-lgtm`（引数 `./tmp/fix-plan.md`）を呼び出す。

### フェーズ 3: 実装

- `plan-lgtm` の完了報告に加え、`./tmp/plan-review.md` を Read ツールで読み「総合判定」フィールドが `LGTM` であることを直接確認する（`plan-lgtm` 内部の判定方式と同じく、完了報告の自然文だけに頼らない決定的な確認）
- 上記が確認できた場合のみ、`Skill` ツールで `implement`（引数 `./tmp/fix-plan.md`）を呼び出す
- `plan-lgtm` が反復上限到達・要再設計・ユーザー中断等で `LGTM` に至らず終了した場合は、**`implement` へは進まず**その時点の状態をそのままユーザーに報告して終了する

### フェーズ 4: 完了報告

`fix`/`plan-lgtm`/`implement` それぞれの実施結果をまとめて報告する:

- `fix`: 生成した修正項目の総数と優先度別件数
- `plan-lgtm`: 反復回数と最終判定（`LGTM` / 上限到達 / 要再設計 / ユーザー中断）
- `implement`: 実施した場合はステップ数・レビューサイクル回数・品質確認結果（未実施の場合はその旨と理由）

## 注意事項

`plan-lgtm` を独立スキルとして `Skill` ツール経由で呼び出すことで、LGTM ループのロジックを本スキルに重複実装しない。
