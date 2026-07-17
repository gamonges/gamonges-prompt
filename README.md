# Claude Skills & SubAgents Collection

Claude Code で使用するための Skills と SubAgents のコレクションです。

## 概要

このリポジトリには、すべてのプロジェクトで共通して使用できる Claude の拡張機能が含まれています。

### 📁 構成

```
claude/
├── skills/              # エージェント スキル（SKILL.md 必須、frontmatter に name と description 必須）
│   ├── ask/
│   ├── design/
│   ├── implement/
│   ├── review/
│   └── ...
├── scripts/             # ユーティリティスクリプト
│   ├── statusline.py
│   ├── sync-cursor-skills.sh
│   └── verify-skills.sh
└── subagents/           # サブエージェント
    ├── 01-core-development/     # コア開発
    ├── 02-language-specialists/ # 言語スペシャリスト
    ├── 03-infrastructure/       # インフラ
    └── 04-quality-security/     # 品質・セキュリティ
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

これにより、以下の場所にシンボリックリンクが作成されます：
- Skills → `~/.claude/skills/`
- SubAgents → `~/.claude/sub-agents/`
- Scripts → `~/.claude/scripts/`

### 状態確認

```bash
./setup.sh status
```

### 検証

```bash
./claude/scripts/verify-skills.sh   # SKILL.md 数 / frontmatter / symlink を機械的に検証
```

### アンインストール

```bash
./setup.sh uninstall
```

### 旧形式からの移行（他端末で旧バージョンを install していた場合）

```bash
git pull
./setup.sh migrate    # 旧形式 (commands→skill 化されたディレクトリ) を撤去
./setup.sh install    # 新形式で再インストール
```

## 📚 Skills 一覧

開発ワークフロー系（旧 commands から移行）と、ユーティリティ系（既存）に分類:

### 開発ワークフロー系
| スキル名 | 説明 |
|---------|------|
| `/ask` | コードベースや技術的質問への調査回答 |
| `/design` | 要件・コンテキストから実装計画 (plan.md) を生成 |
| `/review-plan` | plan.md のスタッフエンジニアレビュー |
| `/revise` | フィードバックに基づき計画ファイルを修正 |
| `/implement` | 計画に基づき TDD で実装 |
| `/review` | PR レビュー（並列サブエージェント） |
| `/fix` | 修正項目から fix-plan.md を生成 |
| `/create-pr` | develop 向けドラフト PR を作成 |
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
| `worktree-cleanup` | マージ済み PR の worktree 一括削除（削除時に claude-context index も回収） |
| `strategic-ddd` / `review-strategic-ddd` | 戦略的 DDD 設計と そのレビュー |

## 🤖 SubAgents 一覧

### Core Development
- `api-designer.md` - API 設計
- `backend-developer.md` - バックエンド開発
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
- `code-reviewer.md` - コードレビュー
- `compliance-auditor.md` - コンプライアンス監査
- `debugger.md` - デバッグ
- `error-detective.md` - エラー調査
- `penetration-tester.md` - ペネトレーションテスト
- `performance-engineer.md` - パフォーマンスエンジニアリング
- `powershell-security-hardening.md` - PowerShell セキュリティ強化
- `qa-expert.md` - QA エキスパート
- `security-auditor.md` - セキュリティ監査
- `test-automator.md` - テスト自動化

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

1. `claude/subagents/` 配下の適切なカテゴリに `.md` ファイルを作成
2. `./setup.sh install` を再実行

## ⚠️ 注意事項

- シンボリックリンクを使用しているため、リポジトリ内のファイルを更新すると自動的に反映されます
- リポジトリを削除すると、リンクが壊れます（アンインストールを先に実行してください）
- 既存の同名ファイルは `.backup.YYYYMMDDHHMMSS` としてバックアップされます
