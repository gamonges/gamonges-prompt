---
name: memory
description: "作業の記憶を保存する。会話をまたいで知見・決定・作業状態を残したい時、`/memory` 呼び出しで使用。実装本体は agent-memory に委譲する。"
---

agent-memory スキルに従って、現在の作業状態を `~/.local/share/claude/memories/` に保存してください。

**保存先の判断基準は agent-memory スキルの「記憶の棲み分け」に従う**（本スキルは全プロジェクト横断スコープを扱い、プロジェクト固有のものは auto-memory 側へ振り分ける）。
