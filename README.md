# Claude Skills & SubAgents Collection

Claude Code で使用するための Skills と SubAgents のコレクションです。

## 概要

このリポジトリには、すべてのプロジェクトで共通して使用できる Claude の拡張機能が含まれています。

### 📁 構成

```
claude/
├── skills/              # エージェント スキル
│   ├── domain-name-brainstormer/
│   └── figma/
└── subagents/           # サブエージェント
    ├── 01-core-development/     # コア開発
    ├── 02-language-specialists/ # 言語スペシャリスト
    ├── 03-infrastructure/       # インフラ
    └── 04-quality-security/     # 品質・セキュリティ
```

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

### 状態確認

```bash
./setup.sh status
```

### アンインストール

```bash
./setup.sh uninstall
```

## 📚 Skills 一覧

| スキル名 | 説明 |
|---------|------|
| `domain-name-brainstormer` | ドメイン名のブレインストーミング |
| `figma` | Figma 関連の操作 |

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
