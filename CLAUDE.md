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

### Opus 4.8 プロンプト規約

skill / subagent のプロンプトは Opus 4.8 の挙動（字義通り・自律的・effort で制御・subagent は控えめに spawn）に合わせる。新規 skill 追加・既存 skill 編集時は以下の変換ルール（T1–T5）と維持リスト（K）に従う。制御の主軸は「強い命令語」ではなく「effort + 条件化された明示指示」に置く。

- **T1（命令語の緩和）**: `CRITICAL: You MUST X when…` → `Use X when…`。`必ず/絶対/厳守` は、安全・不変制約でなければ通常トーンへ。4.8 はオーバートリガーしやすい。
- **T2（subagent の条件化）**: 「常に並列に subagent で調査」ではなく「**複数の独立タスクへ fan-out する場合・複数ファイルを読む場合は同一ターンで複数 spawn。単一の探索や 1 ファイルで完結する作業は直接実行**」。
  - 除外: 並列 subagent が**ワークフローの本質的価値**である箇所（`/review` の並列レビュー、`/implement` Medium/Large の並列編集）は維持する。
- **T3（進捗 scaffolding の削減）**: 「N ステップごとに要約」等の**過程**強制は削除（4.8 は自前で良質な進捗更新をする）。plan.md の確信度サマリ等の**成果物**構造は維持。
- **T4（review の coverage 化）**: finding 段は確信度・重要度に関わらず全件報告し、各 finding に confidence/severity を付す。フィルタ・並べ替えは集約段で行う（「Low は捨てる」ではなく「ラベル付けして下部に並べる」）。
- **T5（網羅煽り→具体基準/effort 委譲）**: 「徹底的に/できる限り多く/exhaustive」は具体的な完了基準に置換。網羅度は effort（xhigh/high）に委ねる。

**維持リスト（K: 変更しない）**: 安全ガード（`Never modify source files` 等）、TDD 規律（「すべての実装はテストから」）、具体的で有効なルール（marp の文字数制限等）、ファイルパス `L{number}` 形式の強制、本質的価値としての並列 subagent 設計（review/implement）。

**モデル依存記述の集約**: モデルバージョンに依存する設計判断は `## 設計思想（{model} baseline）` 節（例: `## 設計思想（Opus 4.8 baseline）`）に集約し、モデル更新時にこの節のみを更新すればよい構造を保つ。

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
