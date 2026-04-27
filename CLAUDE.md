# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

Claude Code で使用する Skills、SubAgents のコレクション。すべてのプロジェクトで共通利用するための拡張機能を管理するリポジトリ。コードの実装はなく、プロンプト（Markdown）の管理が主目的。


## セットアップ

```bash
./setup.sh install    # Skills・SubAgents を ~/.claude/ にシンボリックリンク
./setup.sh status     # インストール状態の確認
./setup.sh uninstall  # シンボリックリンクの削除
./setup.sh migrate    # 旧形式 (commands→skill 化されたディレクトリ) を撤去して新形式へ移行
```

**他端末への展開時の手順**: `git pull && ./setup.sh migrate && ./setup.sh install`

シンボリックリンクにより、リポジトリ内のファイル更新が即座に反映される。
構造的検証は `./claude/scripts/verify-skills.sh` で機械的に実行可能。

## リポジトリ構成

```
claude/
├── skills/             # エージェントスキル（SKILL.md が必須、frontmatter に name と description 必須）
│   ├── ask/
│   ├── design/
│   ├── implement/
│   ├── review/
│   └── ...
├── scripts/            # ユーティリティスクリプト（setup.sh が ~/.claude/scripts/ に symlink）
│   ├── statusline.py
│   ├── sync-cursor-skills.sh
│   └── verify-skills.sh
└── subagents/          # サブエージェント定義（カテゴリ別）
    ├── 01-core-development/
    ├── 02-language-specialists/
    ├── 03-infrastructure/
    └── 04-quality-security/
study/                  # 学習ノート（デプロイ対象外）
```

## 主要ワークフロー（Skills）

Skills は開発ワークフローをパイプラインとして構成している（`/<skill-name>` で呼び出し）:

### 簡易フロー（新規仕様の追加）

```
/ask → /design → /spec-check → /review-plan ⇄ /revise → /implement
  → /review → /fix → /implement fix-plan → /spec-archive → /create-pr
```

### 完全フロー（既存仕様の修正）

```
/ask → /design → /spec-check → /review-plan ⇄ /revise → /implement
  → /review → /fix → /implement fix-plan → /spec-propose → (レビュー) → /spec-archive {change-name} → /create-pr
```

主要 skill は `claude/skills/` 配下、`/<name>` で呼び出し。詳細は各 SKILL.md および `./setup.sh status` で確認できる。

## Skills 共通規約

本リポジトリの全 skill には以下の規約を適用する（各 SKILL.md には `**規約**: CLAUDE.md の Skills 共通規約に従う` の 1 行のみ残し、詳細は再宣言しない）:

- 出力は日本語（技術用語・コード例は英語のまま）
- `tmp/` 配下のファイルはコミットしない
- レビュー指摘・コード参照は `file_path:L{number}` 形式
- ソースコードを変更しない skill は、出力先を skill 本文に明記する（例: `./tmp/research.md`）

## OpenSpec（仕様管理）

```
openspec/
├── config.yaml                  ← プロジェクト固有の設定（任意）
├── specs/                       ← 仕様の正（Single Source of Truth）
│   └── {domain}/spec.md
└── changes/                     ← 変更提案（作業領域）
    ├── {change-name}/
    │   ├── proposal.md          ← Why / What Changes / Impact
    │   ├── specs/{domain}/spec.md  ← delta spec (ADDED/MODIFIED/REMOVED/RENAMED)
    │   ├── design.md            ← 技術設計
    │   └── tasks.md             ← 実装ステップ
    └── archive/                 ← 完了した変更
```

## ファイル追加規約

### Skills の追加
1. `claude/skills/<skill-name>/SKILL.md` を作成（YAML frontmatter に `name` と `description` 必須）
2. `./setup.sh install` を再実行
3. `./claude/scripts/verify-skills.sh` で構造検証

> 補助ファイル（テンプレート、参考資料、検証スクリプト等）は同じ skill ディレクトリ内に配置可（例: `claude/skills/adr/template/adr-template.md`）。

### SubAgents の追加
1. `claude/subagents/<category>/` 配下に `.md` ファイルを作成
2. `./setup.sh install` を再実行
3. `README.md` はセットアップスクリプトがスキップするため、ドキュメント用に使用可

## 言語・スタイル

- Skills の出力は日本語（`Always respond in Japanese`）
- コード参照は `file_path:line_number` 形式（例: `src/module/file.ts:L42`）
- レビュー指摘は `src/full/path/to/file.tsx:L42` 形式で相対パスを使用
