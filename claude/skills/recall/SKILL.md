---
name: recall
description: "保存した記憶を読み込む。前回の続きから作業を再開する時、`/recall` 呼び出しで使用。実装本体は agent-memory に委譲する。"
---

agent-memory スキルに従って、~/.local/share/claude/memories/ から記憶を検索・読み込んでください。
まず summary の一覧を表示し、ユーザーに選択させてから詳細を読み込んでください。
