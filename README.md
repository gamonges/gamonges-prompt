# Claude Skills & SubAgents Collection

Claude Code で使用するための Skills と SubAgents のコレクションです。

## 概要

このリポジトリには、すべてのプロジェクトで共通して使用できる Claude の拡張機能が含まれています。

### 📁 構成

```
claude/
├── agents/              # subagent 定義（~/.claude/agents/ へ配置。Claude Code はサブフォルダも再帰的に読む）
│   ├── 01-core-development/     # コア開発
│   ├── 02-language-specialists/ # 言語スペシャリスト
│   ├── 03-infrastructure/       # インフラ
│   ├── 04-quality-security/     # 品質・セキュリティ
│   ├── 05-business-analysis/    # 業務分析
│   └── 06-architecture/         # アーキテクチャ
├── skills/              # エージェント スキル（SKILL.md 必須、frontmatter に name と description 必須）
│   ├── ask/
│   ├── design/
│   ├── implement/
│   ├── review/
│   └── ...
└── scripts/             # ユーティリティスクリプト
    ├── statusline.py
    ├── sync-cursor-skills.sh
    └── verify-skills.sh
```

> **注**: Anthropic 公式により Custom Commands は Skills に統合されました（出典: https://code.claude.com/docs/en/custom-skills.md ）。本リポジトリでも旧 `claude/commands/` を廃止し、すべて `claude/skills/<name>/SKILL.md` 形式に統一しています。

## 🚀 セットアップ

### インストール

リポジトリをクローンして、セットアップスクリプトを実行します：

```bash
git clone <repository-url>
cd gamonges-prompt
./setup.sh install
```

これにより、以下の場所に配置されます：
- Skills → `~/.claude/skills/`（シンボリックリンク）
- Agents → `~/.claude/agents/`（シンボリックリンク。`claude/agents/<カテゴリ>/` の定義を basename で平置きにする。Claude Code がユーザーレベルの subagent を読み込む場所）
- settings.json → `~/.claude/settings.json`（シンボリックリンク）
- Scripts → `~/.claude/scripts/`（**実体コピー**。編集・pull したら `./setup.sh install` を再実行する）

### 状態確認

```bash
./setup.sh status
```

### 検証

```bash
./claude/scripts/verify-skills.sh   # SKILL.md 数 / frontmatter (name とディレクトリ名の一致) /
                                    # symlink / scripts の同期・orphan・install 元 / listing budget
                                    # fail があれば exit 1、warn のみなら exit 0
```

### アンインストール

```bash
./setup.sh uninstall
```

### 旧形式からの移行（他端末で旧バージョンを install していた場合）

```bash
git pull
./setup.sh migrate    # 旧形式 (commands→skill 化されたディレクトリ・旧配置先 ~/.claude/sub-agents/ のリンク) を撤去
./setup.sh install    # 新形式で再インストール
```

## 📚 Skills 一覧

開発ワークフロー系（旧 commands から移行）と、ユーティリティ系（既存）に分類:

> **起動方法（重要）**: `disable-model-invocation: true` を付けた skill は **`/` 呼び出しのみ**で、自然言語からは起動しない。無反応で終わるのではなく有効な別実装（plugin など）に流れることがあるため、明示的に `/名前` で呼ぶ。
> `settings.json` の `skillOverrides: "name-only"` を付けた skill は listing に name だけ載る（description が落ちるだけで、自然言語からの起動は可能）。
> 現在の状態: `grep -l 'disable-model-invocation: true' claude/skills/*/SKILL.md` と `jq .skillOverrides claude/settings.json`

### 開発ワークフロー系
| スキル名 | 説明 |
|---------|------|
| `/brief` | 用途別テンプレート（concept / implement / refactor / bug）で質問ファイル tmp/context.md を作成（任意の前工程） |
| `/ask` | コードベースや技術的質問への調査回答 |
| `/design` | 要件・コンテキストから実装計画 (plan.md) を生成 |
| `/review-plan` | plan.md のスタッフエンジニアレビュー |
| `/revise` | フィードバックに基づき計画ファイルを修正 |
| `/implement` | 計画に基づき TDD で実装（テストの価値は基盤 skill `test-audit` と判定役 `test-auditor` で監査する） |
| `/review` | PR レビュー（並列サブエージェント） |
| `/fix` | 修正項目から fix-plan.md を生成 |
| `/create-pr` | 既定ブランチ向けドラフト PR を作成（ベースは `gh repo view` から取得） |
| `/spec-check` / `/spec-propose` / `/spec-archive` / `/document-spec` | OpenSpec 仕様管理 |
| `/review-comments` | PR レビューコメントの妥当性評価 + 返信 + resolve |
| `/retrospective` | 日次 PR 振り返り |
| `/adr` / `/state-machine` / `/status` | ADR 生成 / 状態遷移図追加 / ワークフロー進捗表示 |
| `/memory` / `/recall` | 記憶の保存・読み込み（実装は `agent-memory` skill に委譲） |
| `/coupling-audit` / `/coupling-plan-diff` / `/coupling-precheck` / `/coupling-gate` | 結合(Coupling)モデルによる分析4種（既存コード棚卸し / Before-After差分分析 / 設計前整理 / plan.mdゲート） |

### ユーティリティ系
| スキル名 | 説明 |
|---------|------|
| `agent-memory` | 記憶の保存・読み込みの実装本体（`user-invocable: false`） |
| `coupling-anatomy` | 結合モデル判定基準の実装本体（`user-invocable: false`） |
| `domain-name-brainstormer` | ドメイン名のブレインストーミング |
| `figma` | Figma 関連の操作 |
| `marp` | Marp スライド生成 |
| `blog` / `outline` | ブログドラフト / アウトライン生成 |
| `notion-adr` / `notion-qa-progress` | Notion 連携 |
| `playwright-cli` | ブラウザ自動操作 |
| `context-index` | claude-context にコードベースを index（個人定義の ignore で不要ディレクトリ除外、`disable-model-invocation`） |
| `worktree-cleanup` | マージ済み PR の worktree 一括削除（削除時に claude-context index を回収、孤児 collection の点検も行う） |
| `strategic-ddd` / `review-strategic-ddd` | 戦略的 DDD 設計と そのレビュー |
| `skill-authoring` | skill / subagent を書くときの規約（Claude 5 向け変換ルール T1–T8、起動制御フィールドの判断表、追加手順）。**起動制御の正本** |

## 🤖 SubAgents 一覧

すべて `claude/agents/<カテゴリ>/` にあり、`~/.claude/agents/` に配置される。code-reviewer と qa-expert は、pr-review-toolkit の `code-reviewer` / `pr-test-analyzer` と比べて plugin 版を採用し、削除した（2026-09-30）。

### Core Development
- `api-designer.md` - API 設計
- `backend-developer.md` - バックエンド開発
- `ddd-expert.md` - 戦術的 DDD（Entity / Value Object の分類・集約の設計）
- `documenter.md` - 仕様・計画とコードの同期（`/implement` Phase 5.5）
- `frontend-developer.md` - フロントエンド開発
- `fullstack-developer.md` - フルスタック開発
- `ui-designer.md` - UI デザイン

### Language Specialists
- `typescript-pro.md` - TypeScript エキスパート

### Infrastructure
- `cloud-architect.md` - クラウドアーキテクト
- `database-administrator.md` - データベース管理
- `devops-engineer.md` - DevOps エンジニア
- `devops-incident-responder.md` - DevOps インシデント対応
- `security-engineer.md` - セキュリティエンジニア
- `sql-pro.md` - SQL エキスパート
- `sre-engineer.md` - SRE エンジニア

### Quality & Security
- `accessibility-tester.md` - アクセシビリティテスト
- `ad-security-reviewer.md` - AD セキュリティレビュー
- `architect-reviewer.md` - アーキテクチャレビュー
- `chaos-engineer.md` - カオスエンジニアリング
- `compliance-auditor.md` - コンプライアンス監査
- `debugger.md` - デバッグ
- `error-detective.md` - エラー調査
- `penetration-tester.md` - ペネトレーションテスト
- `performance-engineer.md` - パフォーマンスエンジニアリング
- `powershell-security-hardening.md` - PowerShell セキュリティ強化
- `security-auditor.md` - セキュリティ監査
- `test-auditor.md` - テストの価値の読み取り専用判定役（`/implement` の主担当表・変更監査。`test-audit` を preload）
- `test-automator.md` - テスト自動化

### Business Analysis
- `bpmn-expert.md` - BPMN 2.0 と BPM の実装設計
- `process-modeler.md` - 業務プロセスの分析・モデリング

### Architecture
- `design-system-architect.md` - デザインシステム・UI 基盤
- `frontend-architect.md` - フロントエンドアーキテクチャ
- `react-architect.md` - React エコシステムのアーキテクチャ
- `senior-architect.md` - 設計フェーズの非機能要件の評価・技術選定
- `strategic-ddd-designer.md` - 戦略的 DDD（`strategic-ddd` を preload）

## 🔗 参考リンク

- [Claude Code Skills 公式ドキュメント](https://code.claude.com/docs/ja/skills)
- [Claude Code Sub-agents 公式ドキュメント](https://code.claude.com/docs/ja/sub-agents)

## 📝 新しい Skills/SubAgents の追加

### Skills の追加

1. `claude/skills/` 配下に新しいディレクトリを作成
2. `SKILL.md` ファイルを作成（必須）
3. `./setup.sh install` を再実行

```yaml
---
name: your-skill-name
description: Brief description of what this Skill does
---

# Your Skill Name

## Instructions
...
```

### SubAgents の追加

1. `claude/agents/<カテゴリ>/` に `.md` ファイルを作成する。frontmatter の `name` はファイル名と一致させ、`claude/agents/` 全体で一意にする（書き方の規約は `claude/skills/skill-authoring/SKILL.md` の「SubAgents の追加」）
2. `./setup.sh install` を再実行（`~/.claude/agents/` を初めて作った場合は、Claude Code のセッションを開き直す）

## ⚠️ 注意事項

- Skills / Agents / settings.json はシンボリックリンクのため、リポジトリ内のファイルを更新すると自動的に反映されます
- **Scripts は実体コピーのため即時反映されません。** `claude/scripts/` を編集・pull したら `./setup.sh install` を再実行してください。忘れても hook は失敗せず古いスクリプトで静かに動き続けます（同期状態は `./setup.sh status` か `verify-skills.sh` で確認）
- リポジトリを削除すると、リンクが壊れます（アンインストールを先に実行してください）
- 既存の同名ファイルは、内容が異なる場合に `.backup.YYYYMMDDHHMMSS` としてバックアップされます
- **install はメインチェックアウトから実行してください。** worktree から実行すると symlink がその worktree を指し、削除時に設定が失われます（`./setup.sh install` が警告します）
