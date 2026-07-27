---
name: recall
description: "保存した記憶を読み込む。前回の続きから作業を再開する時、`/recall` 呼び出しで使用。実装本体は agent-memory に委譲する。"
---

agent-memory スキルに従って、`~/.local/share/claude/memories/`（全プロジェクト横断の記憶）から検索・読み込んでください。
まず summary の一覧を表示し、ユーザーに選択させてから詳細を読み込んでください。

スコープの棲み分けは agent-memory スキルの「記憶の棲み分け」に従う（プロジェクト固有の記憶は auto-memory 側で自動想起されるため本スキルの対象外）。横断スコープの記憶が見つからない場合はその旨を伝える。
