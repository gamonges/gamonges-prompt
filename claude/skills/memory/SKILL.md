---
name: memory
description: "作業の記憶を保存する。会話をまたいで知見・決定・作業状態を残したい時、`/memory` 呼び出しで使用。実装本体は agent-memory に委譲する。"
---

agent-memory スキルに従って、現在の作業状態を `~/.local/share/claude/memories/` に保存してください。

**保存先の判断**: 本スキルは**全プロジェクト横断**の記憶を扱う。保存対象が**そのプロジェクト固有**（当該リポジトリの決定・作業状態・教訓）なら、`~/.local/share/claude/memories/` ではなく **auto-memory**（`.claude/projects/<project>/memory/`）へ保存する。棲み分けの詳細は agent-memory スキルを参照。
