---
name: memory
description: "作業の記憶を保存する。会話をまたいで知見・決定・作業状態を残したい時、`/memory` 呼び出しで使用。実装本体は agent-memory に委譲する。"
---

agent-memory スキルに従って、現在の作業状態を `~/.local/share/claude/memories/` に保存してください。

**注意**: システムプロンプトの "auto memory" ディレクトリ（`.claude/projects/.../memory/`）とは別の仕組みです。必ず `~/.local/share/claude/memories/` に保存すること。
