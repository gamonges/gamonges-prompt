# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

Claude Code で使用する Skills、SubAgents、Commands のコレクション。すべてのプロジェクトで共通利用するための拡張機能を管理するリポジトリ。コードの実装はなく、プロンプト（Markdown）の管理が主目的。

## セットアップ

```bash
./setup.sh install    # Skills・SubAgents を ~/.claude/ にシンボリックリンク
./setup.sh status     # インストール状態の確認
./setup.sh uninstall  # シンボリックリンクの削除
```

シンボリックリンクにより、リポジトリ内のファイル更新が即座に反映される。

## リポジトリ構成

```
claude/
├── commands/           # スラッシュコマンド定義（/design, /implement, /review 等）
│   └── template/       # コマンド用テンプレート（ADR テンプレート等）
├── skills/             # エージェントスキル（SKILL.md が必須）
│   ├── domain-name-brainstormer/
│   ├── figma/
│   └── notion-qa-progress/
└── subagents/          # サブエージェント定義（カテゴリ別）
    ├── 01-core-development/
    ├── 02-language-specialists/
    ├── 03-infrastructure/
    └── 04-quality-security/
study/                  # 学習ノート（デプロイ対象外）
```

## 主要ワークフロー（Commands）

Commands は開発ワークフローをパイプラインとして構成している:

```
/design → /revise → /implement → /review → /fix → /implement ./tmp/fix-plan.md → /create-pr
```

- `/design`: コンテキストファイル（`./tmp/context.md`）から `./tmp/plan.md` を生成。ファイル変更なし
- `/revise`: フィードバックに基づき `./tmp/plan.md` を修正。変更後に自動コミット
- `/implement`: plan.md に基づきコードを実装。TDD 必須、各ステップでレビューサイクル2回
- `/review`: PR の差分をサブエージェント並列実行でレビュー。`./tmp/review.md` に統合レポート出力
- `/fix`: 実装後の修正項目（`./tmp/fixes.md`）と `/review` 出力から `./tmp/fix-plan.md` を生成。ソース変更なし
- `/create-pr`: ブランチから develop 向けドラフト PR を作成。`DC-xxxx` 形式の Notion ID を ref 行として付与可能
- `/review-comments`: PR レビューコメントの妥当性評価と対応方針策定。ソース変更なし
- `/ask`: コードベースや技術的質問への調査回答。ソース変更なし
- `/retrospective`: 日次 PR 振り返り（standandforce org の5リポジトリが対象）
- `/adr`: ADR（Architecture Decision Record）を日本語で生成
- `/state-machine`: plan ファイルに状態遷移図（ASCII）を追加

## ファイル追加規約

### Skills の追加
1. `claude/skills/<skill-name>/SKILL.md` を作成（YAML frontmatter + Instructions）
2. `./setup.sh install` を再実行

### SubAgents の追加
1. `claude/subagents/<category>/` 配下に `.md` ファイルを作成
2. `./setup.sh install` を再実行
3. `README.md` はセットアップスクリプトがスキップするため、ドキュメント用に使用可

### Commands の追加
1. `claude/commands/` 配下に `.md` ファイルを作成
2. frontmatter に `description` を記述

## 言語・スタイル

- Commands/Skills の出力は日本語（`Always respond in Japanese`）
- コード参照は `file_path:line_number` 形式（例: `src/module/file.ts:L42`）
- レビュー指摘は `src/full/path/to/file.tsx:L42` 形式で相対パスを使用
