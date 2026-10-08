---
name: <skill-name>
description: <何をする skill か + いつ使うか。120 字以内（T7 / verify-skills.sh check 5 の閾値）>
# 起動制御フィールドの選び方は shared/skills/skill-authoring/SKILL.md の判断表（正本）を見る。
# 要点だけ: disable-model-invocation: true は Claude の自動起動に加えて Skill ツール呼び出し・
# subagent preload・scheduled task 起動もブロックするので、どこからも呼ばれない終端 skill にのみ使う。
# 付けたら agents/openai.yaml（policy: allow_implicit_invocation: false）も置く。Codex はこのフィールドを読まない（verify の check 9）
# listing budget を空けたいだけなら settings.json の skillOverrides: "name-only" を選ぶ。
---

> **新規 skill 作成時のテンプレート**。
> このディレクトリは `_` プレフィックスで `setup.sh:install_skills()` の対象外。
> コピーして `shared/skills/<新skill名>/SKILL.md` を作成し、本テンプレートに従って記述する。

## パラメーター

`$ARGUMENTS` で何を受け取るかを記述する。省略時のデフォルト挙動も明記。

## ワークフロー上の位置付け

| 前工程 | 本コマンド | 後工程 |
|--------|-----------|--------|
| {前 skill} | `/<skill-name>` | {後 skill} |

## 実行条件

skill 実行に必要なファイル / 環境を列挙する。条件未達時は即座に停止してユーザーに報告する。

## 実行プロセス

### フェーズ 1: ...

メインフローのステップを段階的に記述。冗長な汎用説明は避け、AGENTS.md の Skills 共通規約で代替できる内容は再宣言しない。

## 注意事項

- 補助ファイル（テンプレート、checklist 等）が大量にある場合は `reference/*.md` に分離し、SKILL.md からは「条件付き参照指示」のみ記載する
- description の冗長表現を避ける（適合判定には主要トリガー 2-3 個で十分）

## Gotchas

詳細は `./reference/gotchas.md`（存在時のみ参照）。

**運用ルール**:

- SKILL.md には書かず必ず `reference/gotchas.md` に追記
- 同じ罠が 3 回以上発生 → 構造的対策（script / hook / template）に昇格させて gotchas.md から削除
- 半年以上発生していない罠 → `reference/gotchas-archive.md`（無ければその時点で作成する）に移動
