---
name: stack-pr-sync
description: スタック PR をリモートと同期し rebase・push・PR 状態更新を行う。破壊的操作のためユーザー確認必須。「スタック同期」「rebase して push」`/stack-pr-sync` で使用
disable-model-invocation: true
---

現在のスタックをリモートと同期する。GitHub 公式拡張 `gh-stack` の薄いラッパーとして `gh stack sync` を実行する。fetch → trunk の fast-forward → スタック内の cascade rebase → 全ブランチの atomic push（`--force-with-lease`）→ PR 状態同期 → スタックのリンクをまとめて行う破壊的操作のため、実行前に必ずユーザー確認を取る。

## 前提条件チェック

詳細は `../stack-pr-init/SKILL.md` の「前提条件チェック（SSOT）」を参照し同じチェックを行う（再宣言しない）。

## 実行プロセス

1. 前提条件チェックを実行する
2. `gh stack view` で現在のスタック構成と `⚠`（rebase 要）が付いているブランチを提示する
3. rebase による履歴書き換えと force-with-lease push を伴う旨を説明し、**ユーザー確認を取る**（CLAUDE.md の破壊的操作確認方針に従う）。マージ済み PR のローカルブランチを削除する `--prune` の要否も併せて確認する
4. 確認後、`gh stack sync`（`--prune` 指定時は付与）を実行する
   - ローカル/リモートが分岐（divergence）している場合、非対話実行では push や PR 更新を行わずに自動 abort する（安全側の挙動）。abort された場合はその旨をそのまま報告し、自動リトライしない
   - rebase conflict が発生した場合、全ブランチは元の状態に復元され「`gh stack rebase` で対話的に解決してください」という案内が出る。本 skill では対話的な conflict 解決を代行できないため、エラー内容をそのまま報告し、ユーザーに手動での `gh stack rebase` 実行を促す（`gh stack sync --help` の記述に基づく設計。rebase conflict / divergence 時の実挙動は実機未検証）
5. 完了報告: 同期結果（"Stack synced" / "Branches synced" のいずれか）、rebase・push されたブランチ一覧、`--prune` 指定時は削除されたブランチ一覧を報告する。次のアクションとして、未 submit のレイヤーがあれば `/stack-pr-submit`、構成確認は `/stack-pr-view` を案内する
