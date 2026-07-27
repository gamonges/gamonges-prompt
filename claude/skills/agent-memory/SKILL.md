---
name: agent-memory
description: |
  Save and restore working memory across conversations.
  Triggers: "remember", "save this", "recall", "continue from last time".
  Store research findings, decisions, problem solutions, and work state.
user-invocable: false
---

# Agent Memory

**全プロジェクト横断**で参照する知識を保存する記憶システム。

## 記憶の棲み分け

記憶は 2 系統あり、**スコープで使い分ける**。

| 置き場 | スコープ | 想起のされ方 | 用途 |
|--------|---------|-------------|------|
| **auto-memory**（`.claude/projects/<project>/memory/`） | プロジェクト単位 | 自動（`MEMORY.md` の索引が常駐し、関連する記憶だけが必要時に注入される） | そのプロジェクト固有の知見・決定・作業状態・教訓（`type: feedback`） |
| **本スキル**（`~/.local/share/claude/memories/`） | **グローバル（全プロジェクト）** | 明示（`ls` / `rg` で検索） | 書籍・モデル・共通ツールの知見など、プロジェクトを跨いで再利用するもの |

**プロジェクト固有の内容は auto-memory へ。** 本スキルは auto-memory にない「横断スコープ」を担うために残している。

## 保存すべき内容

- 全プロジェクトで再利用する参照知識（設計モデル、書籍の要約、共通ツールの知見）
- 複数プロジェクトに跨る調査で得た知見
- 特定プロジェクトに閉じないアーキテクチャ判断の背景

## ファイル形式

```markdown
---
summary: "簡潔な要約（検索用）"
created: YYYY-MM-DDTHH:MM:SS+09:00
tags: [tag1, tag2]
---

# タイトル

内容...
```

## 検索方法

```bash
# カテゴリ一覧
ls ~/.local/share/claude/memories/

# summary で検索
rg "summary:" ~/.local/share/claude/memories/

# キーワード検索
rg "検索語" ~/.local/share/claude/memories/
```

## 操作

- **保存**: カテゴリフォルダを作成し、markdown ファイルを保存
- **更新**: frontmatter に `updated: YYYY-MM-DD` を追加
- **削除**: 不要になったファイルを削除
- **統合**: 関連する記憶を1つにまとめる

## 原則

- summary は検索で内容を判断できる程度に具体的に
- 再開時に必要な情報を全て含める（自己完結）
- 決定事項とその理由を記録する
