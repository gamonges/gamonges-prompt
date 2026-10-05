---
name: integration-test-scenario
description: PR・実装変更から統合テストのシナリオ手順書を作成する。検証観点を集約し操作手順をテンプレ化して疎通確認してから確定する。「統合テスト」「シナリオ作成」のキーワードで使用。integration-test-run の前工程。
---

## パラメーター

`$ARGUMENTS` で検証対象の変更内容（PR の説明・diff の要約・自由記述）を指定できる。省略時は現在のブランチの `git diff <デフォルトブランチ>...HEAD` を変更内容として使用する。

変更した capability に `openspec/specs/<capability>/verification.md` が存在する場合は、それを一次資料として読む（下記「verification.md の引き継ぎ」）。

## ワークフロー上の位置付け

| 前工程 | 本コマンド | 後工程 |
|--------|-----------|--------|
| `/implement` または `/fix` 適用後 | `integration-test-scenario` シナリオ作成 | `integration-test-run` → `/create-pr` |

## 実行条件

- `$ARGUMENTS`（省略時 `git diff <デフォルトブランチ>...HEAD`）
- 対象アプリケーションの dev 環境が起動していること（フェーズ 3 の疎通確認で検出する）
- playwright-cli が利用可能であること（`shared/skills/playwright-cli/SKILL.md` 参照）

## verification.md の引き継ぎ（存在する場合）

① 実装直後の検証（`verify-scenario`）で使った Driving 行は、② の観点をゼロから起こす代わりの素材になる。書式の正典は `shared/skills/verify-scenario/reference/verification-format.md`。

| verification.md | 本 skill の出力（`./reference/scenario-template.md`） |
|---|---|
| `Driving it` の各行 | ① 観点一覧の 1 観点 |
| `How to get to it` | ③ 各経路の UI 操作手順 |
| `Side effect:` | 判定の裏取り（network 実測に加えて DB の読み戻し） |
| ① の判定 `<確度> / <合否>` | **確度はそのまま引き継ぐ**（同じ 4 区分を共有）。合否は ② で取り直す |
| 確度が `—` の行（`— / blocked` / `— / draft`） | **引き継がない** — 確認そのものが成立しておらず、観点にもならない |

確度を引き継げるのは、`shared/skills/integration-test-run/reference/report-template.md` の「実機live」の証拠に `Side effect:` SQL の読み戻しが含まれているため。証拠の定義が揃っていない状態で引き継ぐと「実機live と書いてあるのに network ログが無い」という不整合が出る。

**フェーズ 3 の疎通確認は省略しない。** verification.md があっても、そこに書かれた ID やデータがこの環境に存在する保証は無い。

## 実行プロセス

### フェーズ 1: スコープ確定

**変更した capability に `verification.md` がある場合、diff からの観点集約は `Driving it` に無い観点に限定する**（上記「verification.md の引き継ぎ（存在する場合）」節が素材の対応を定義している）。同じ観点を 2 系統から起こすと、① の観点一覧に重複が並ぶ。

変更内容からコアの共通関数を特定する（grep/Serena）。そのコア関数を呼び出す全シンクを source 検索で洗い出し、UI パターン・入出力形状でグルーピングして検証観点を N 個に集約する。

原則: 経路数が多くても「コア 1 つ × シンク N 種」に分解できれば、観点は経路数分ではなく共通観点+差分点に収束する。

### フェーズ 2: シナリオ作成

グルーピングごとに操作テンプレートを 1 つ作成し、経路ごとの差分は URL/endpoint/パラメータのみに留める。判定基準は手順に埋め込まず、`shared/skills/integration-test-run/reference/judgment-checklist.md` への参照として記載する。

### フェーズ 3: 環境&データ準備（ライブブラウザ操作）

playwright-cli（`shared/skills/playwright-cli/SKILL.md` および拡張 `references/integration-testing-patterns.md`）で以下を行う:

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
