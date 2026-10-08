---
name: stack-pr-view
description: 現在のスタック PR の構成・状態を表示する読み取り専用 skill。「スタック確認」「スタック状態」`/stack-pr-view` で使用
---

現在のスタックのブランチ構成と各 PR の状態（open / queued / merged / rebase 要否）を表示する。読み取り専用で、GitHub 上のリソースや作業ブランチを変更しない。

## 前提条件チェック

`gh stack view` 自体が `gh-stack` 拡張に依存するため、表示専用の本 skill でも拡張の存在確認・自動インストールが必要になる場合がある。詳細は `../stack-pr-init/SKILL.md` の「前提条件チェック（SSOT）」を参照し同じチェックを行う（再宣言しない）。未インストール時のインストール実行はシステム変更を伴う点をユーザーに一言表示してから行う。

## 実行プロセス

1. 前提条件チェックを実行する
2. `gh stack view` を実行する
3. 結果を人間が読みやすい形に整形して提示する（ブランチ名、PR番号・URL、ステータスアイコンの意味 `✓` PR merged / `◎` PR queued / `○` PR open / `⚠` rebase 要）
4. `⚠` が含まれる場合は「`/stack-pr-sync` で解消できます」と案内する
