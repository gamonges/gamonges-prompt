---
name: integration-test-run
description: |
  integration-test-scenario が作成したシナリオ手順書を実施する。playwright-cliのnetwork層キャプチャで観点を実測判定し、非2xxや失敗は回帰か環境要因かを切り分けてから4区分のstatusで結果を記録する。
  「統合テスト実施」「シナリオ実行」「テスト実行」等のキーワードで使用。integration-test-scenario の後工程。
---

**規約**: CLAUDE.md の Skills 共通規約に従う

## 補助ドキュメントへの参照

| 補助ドキュメント | 読むタイミング |
|------------------|----------------|
| `./reference/judgment-checklist.md` | フェーズ 3 で非 2xx や失敗を回帰か環境要因かに切り分ける時 |
| `./reference/report-template.md` | フェーズ 4 で結果を記録する時 |

「念のため全部読む」は禁止。表のトリガー条件に該当する場合のみ読み込む。

## パラメーター

`integration-test-run [scenario-file]` の形式。省略時は `./tmp/integration-test-scenario.md` を参照する。

## ワークフロー上の位置付け

| 前工程 | 本コマンド | 後工程 |
|--------|-----------|--------|
| `integration-test-scenario` | `integration-test-run` シナリオ実行 | `/create-pr` |

## 実行条件

- `[scenario-file]`（省略時 `./tmp/integration-test-scenario.md`）が存在すること。存在しなければ即座に停止し、`integration-test-scenario` の先行実行をユーザーに案内する
- 対象アプリケーションの dev 環境が起動していること

## 実行プロセス

### フェーズ 1: シナリオ読み込み

シナリオファイルから観点一覧・経路×観点対応表・操作手順を把握する。

### フェーズ 2: 実施（network 層キャプチャ）

`claude/skills/playwright-cli/references/integration-testing-patterns.md` の network キャプチャ雛形（1 コールに閉じたリスナ登録→操作→wait→return）で各経路を実施する。UI の見た目だけで成功判定しない。実際に発生したリクエストの method/status/URL/content-type 等を実測する。

### フェーズ 3: 判定（回帰 vs 環境要因）

非 2xx や失敗を検出した場合、直ちに回帰と結論しない。`./reference/judgment-checklist.md` の汎用パターンと照合して環境要因の可能性を先に切り分け、条件を変えた再現（別パラメータ・再ログイン等）で結論を出す。

原則: 複数経路が同時に落ちた場合はインフラ要因を疑う。障害期の結果は破棄し、健全期のみ採用する。

### フェーズ 4: 記録

`./tmp/integration-test-results.md` に `./reference/report-template.md` の構成で出力する。

- ① サマリ表（status区分×件数）
- ② 観点別全経路結果
- ③ 経路別テーブル（URL/発行method+status/実測status/トースト等）
- ④ 実測ログ抜粋
- ⑤ 発見・注意
- ⑥ 参照実装

「できなかった範囲＋根拠」も明記し、緑一色で丸めない。
