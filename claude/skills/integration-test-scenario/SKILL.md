---
name: integration-test-scenario
description: |
  PR・実装変更から統合テストのシナリオ手順書を作成する。コア共通関数とシンク一覧をsourceで特定して検証観点に集約し、経路をUIパターンでグルーピングして操作手順をテンプレ化、playwright-cliのライブ操作で疎通・有効ID・フィクスチャを確認してから手順書を確定する。
  「統合テスト」「シナリオ作成」「テストシナリオ」等のキーワードで使用。実装完了後・PR作成前の検証準備に使う。integration-test-run の前工程。
---

**規約**: CLAUDE.md の Skills 共通規約に従う

## パラメーター

`$ARGUMENTS` で検証対象の変更内容（PR の説明・diff の要約・自由記述）を指定できる。省略時は現在のブランチの `git diff <デフォルトブランチ>...HEAD` を変更内容として使用する。

## ワークフロー上の位置付け

| 前工程 | 本コマンド | 後工程 |
|--------|-----------|--------|
| `/implement` または `/fix` 適用後 | `integration-test-scenario` シナリオ作成 | `integration-test-run` → `/create-pr` |

## 実行条件

- `$ARGUMENTS`（省略時 `git diff <デフォルトブランチ>...HEAD`）
- 対象アプリケーションの dev 環境が起動していること（フェーズ 3 の疎通確認で検出する）
- playwright-cli が利用可能であること（`claude/skills/playwright-cli/SKILL.md` 参照）

## 実行プロセス

### フェーズ 1: スコープ確定

変更内容からコアの共通関数を特定する（grep/Serena）。そのコア関数を呼び出す全シンクを source 検索で洗い出し、UI パターン・入出力形状でグルーピングして検証観点を N 個に集約する。

原則: 経路数が多くても「コア 1 つ × シンク N 種」に分解できれば、観点は経路数分ではなく共通観点+差分点に収束する。

### フェーズ 2: シナリオ作成

グルーピングごとに操作テンプレートを 1 つ作成し、経路ごとの差分は URL/endpoint/パラメータのみに留める。判定基準は手順に埋め込まず、`claude/skills/integration-test-run/reference/judgment-checklist.md` への参照として記載する。

### フェーズ 3: 環境&データ準備（ライブブラウザ操作）

playwright-cli（`claude/skills/playwright-cli/SKILL.md` および拡張 `references/integration-testing-patterns.md`）で以下を行う:

- 依存先への疎通を確認する
- 必要なフィクスチャを生成する
- 有効なテスト ID/レコードをライブ操作の 3 手（`references/integration-testing-patterns.md` の「有効 ID 発見の 3 手」）で発見する

この工程を経ずにシナリオを確定しない。存在しない ID や実際と異なる UI パターンを前提にした、実施不能な手順書になるリスクを避けるため。

### フェーズ 4: 出力

`./tmp/integration-test-scenario.md` に以下を出力する。テンプレートは `./reference/scenario-template.md` を参照。

- ① 観点一覧
- ② 経路×観点の対応表
- ③ 各経路の UI 操作手順
- ④ 判定基準の参照先
