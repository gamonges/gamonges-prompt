# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

Claude Code で使用する Skills、SubAgents のコレクション。すべてのプロジェクトで共通利用するための拡張機能を管理するリポジトリ。コードの実装はなく、プロンプト（Markdown）の管理が主目的。


## セットアップ

```bash
./setup.sh install    # Skills・SubAgents・settings.json を ~/.claude/ にシンボリックリンク
./setup.sh status     # インストール状態の確認
./setup.sh uninstall  # シンボリックリンクの削除
./setup.sh migrate    # 旧形式 (commands→skill 化されたディレクトリ) を撤去して新形式へ移行
```

**他端末への展開時の手順**: `git pull && ./setup.sh migrate && ./setup.sh install`

シンボリックリンクにより、リポジトリ内のファイル更新が即座に反映される。
構造的検証は `./claude/scripts/verify-skills.sh` で機械的に実行可能。

### settings.json のリポジトリ管理

`~/.claude/settings.json` は repo 内 `claude/settings.json` への symlink として管理する。Git 履歴で変更追跡 + `git restore` でロールバック可能。`./setup.sh install` が冪等に symlink を再構築する。

### env-var indirection パターン（機微情報の正規取り扱い）

本リポジトリは **PUBLIC** リポジトリ。`claude/settings.json` にリテラルな API キー / トークン / シークレットを書くことは**禁止**。

**ルール**:

- 機微情報は `~/.zshrc` で `CLAUDE_CODE_{用途}_{種別}` 形式の環境変数として `export`
- 子プロセスへの注入が必要なら `OTEL_EXPORTER_OTLP_HEADERS` 等の最終形変数も `~/.zshrc` で `export`（Claude Code は settings.json `env` 内の `${VAR}` 展開を**非サポート**）
- `claude/settings.json` には機微情報を含めない

**例**:

```bash
# ~/.zshrc
export CLAUDE_CODE_TELEMETRY_DD_API_KEY=<datadog-api-key>
export OTEL_EXPORTER_OTLP_HEADERS="DD-API-KEY=$CLAUDE_CODE_TELEMETRY_DD_API_KEY"
```

新規 commit 時は `git diff --cached claude/settings.json | grep -iE '[a-f0-9]{32}|key=[a-zA-Z0-9]{20,}' | grep -v '\${'` が 0 件であることを確認する。

### portability 課題（F-7 で対応予定）

`claude/settings.json` には個人固有絶対パス（mise の Node 絶対パス、`statusLine.command` の絶対パス等）が含まれる。別端末への展開は F-7 解決まで非対応。

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

本リポジトリの全 skill には以下の規約を適用する（各 SKILL.md では詳細を再宣言しない）:

- 出力は日本語（技術用語・コード例は英語のまま）
- `tmp/` 配下のファイルはコミットしない
- レビュー指摘・コード参照は `file_path:L{number}` 形式
- ソースコードを変更しない skill は、出力先を skill 本文に明記する（例: `./tmp/research.md`）
- 成果物を人が読む形にする場合、完了報告に続けて **Artifact 化を提案する（既定）**。実行時は `artifact-design` skill に従い、`html-view` の reference は参照しない（設計指針を二重管理しないため）。ローカルに閉じたい場合のみ `/html-view <file>` を案内する

> skill / subagent を書くときのプロンプト規約（Claude 5 向けの変換ルール T1–T8、維持リスト K、起動制御フィールドの選び方、追加手順）は `claude/skills/skill-authoring/SKILL.md` に集約している。

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
