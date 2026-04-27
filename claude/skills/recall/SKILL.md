---
name: recall
description: "保存した記憶を読み込むユーザー向けエントリー (/recall)。実装本体は agent-memory スキルに委譲する"
---

agent-memory スキルに従って、~/.local/share/claude/memories/ から記憶を検索・読み込んでください。
まず summary の一覧を表示し、ユーザーに選択させてから詳細を読み込んでください。
