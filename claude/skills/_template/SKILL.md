---
name: <skill-name>
description: <150-200 字以内、動詞 + 目的 + 主要トリガー 2-3 個。「何 + どんな時に使うか」が分かる最小情報>
# 起動制御フィールド（公式: https://code.claude.com/docs/en/skills）。両者は別物・両立可能:
#   disable-model-invocation: true  → / メニューに表示するが、Claude 自動呼出は禁止（例: /commit のような副作用ある操作）
#   user-invocable: false           → / メニューに表示しないが、Claude は呼出可能（例: バックグラウンド知識）
# 両方とも省略すれば user / Claude 両方から呼出可能（デフォルト）
---

**規約**: CLAUDE.md の Skills 共通規約に従う

> **新規 skill 作成時のテンプレート**。
> このディレクトリは `_` プレフィックスで `setup.sh:install_skills()` の対象外。
> コピーして `claude/skills/<新skill名>/SKILL.md` を作成し、本テンプレートに従って記述する。

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

メインフローのステップを段階的に記述。冗長な汎用説明は避け、CLAUDE.md の共通規約で代替できる内容は再宣言しない。

## 注意事項

- 補助ファイル（テンプレート、checklist 等）が大量にある場合は `reference/*.md` に分離し、SKILL.md からは「条件付き参照指示」のみ記載する
- description の冗長表現を避ける（適合判定には主要トリガー 2-3 個で十分）

## Gotchas

詳細は `./reference/gotchas.md`（存在時のみ参照）。

**運用ルール**:

- SKILL.md には書かず必ず `reference/gotchas.md` に追記
- 同じ罠が 3 回以上発生 → 構造的対策（script / hook / template）に昇格させて gotchas.md から削除
- 半年以上発生していない罠 → `reference/gotchas-archive.md` に移動
