---
name: skill-authoring
description: skill / subagent を新規追加・編集する時の規約。Claude 5 向けのプロンプト変換ルール（T1–T8）、起動制御フィールドの選び方、追加手順。`/skill-authoring` 呼び出しでも使用。
---

本リポジトリの skill / subagent を書くときの規約。**Skills 共通規約（出力言語・`tmp/` の扱い・`L{number}` 形式）は `CLAUDE.md` にあり、ここでは再宣言しない。**

## Claude 5 プロンプト規約

skill / subagent のプロンプトは Claude 5 世代の挙動に合わせる。制御の主軸は「強い命令語」ではなく **「effort + 条件化された明示指示」**。

前提となる設計思想は [The new rules of context engineering for Claude 5 generation models](https://claude.com/blog/the-new-rules-of-context-engineering-for-claude-5-generation-models)。Anthropic は Claude Code の system prompt の 80% 以上を削除してもコーディング評価が落ちないことを確認しており、**過剰な制約を外してモデルの判断に委ねる**のが基本方針。

### 変換ルール（T1–T8）

- **T1（命令語の緩和）**: `CRITICAL: You MUST X when…` → `Use X when…`。`必ず/絶対/厳守` は、安全・不変制約でなければ通常トーンへ。オーバートリガーを招く。
- **T2（subagent の条件化）**: 「常に並列に subagent で調査」ではなく「**複数の独立タスクへ fan-out する場合・複数ファイルを読む場合は同一ターンで複数 spawn。単一の探索や 1 ファイルで完結する作業は直接実行**」。
  - 除外: 並列 subagent が**ワークフローの本質的価値**である箇所（`/review` の並列レビュー、`/implement` Medium/Large の並列編集）は維持する。
- **T3（進捗 scaffolding の削減）**: 「N ステップごとに要約」「3 周レビュー」等の**回数・過程**の強制は削除する。**構造を足すのは「次の反復のトリガー」と「完了の定義」を名指しできる時だけ**。plan.md の確信度サマリ等の**成果物**構造は維持。
  - 反復を書くときは「**開始トリガー / 反復トリガー / 完了条件 / 打ち切り（上限 + 到達時の報告義務）**」の 4 点を必ず名指しする。**打ち切りのない反復は書かない** — 上限は 3 巡を既定とし、到達したら完了扱いにせず残る指摘と収束しない理由を報告する。上限のない内側ループを上限つきの外側ループが呼ぶと総コストの上界が誰にも書けなくなる。
- **T4（review の coverage 化）**: finding 段は確信度・重要度に関わらず全件報告し、各 finding に confidence/severity を付す。フィルタ・並べ替えは集約段で行う。
- **T5（網羅煽り→具体基準/effort 委譲）**: 「徹底的に/できる限り多く/exhaustive」は具体的な完了基準に置換。網羅度は effort（xhigh/high）に委ねる。
- **T6（重複排除）**: 同じ指示を skill 本文・description・subagent 定義で繰り返さない。ガイダンスは最も近い定義側に 1 回だけ置く。
- **T7（listing budget）**: `description` は **120 字以内、キーユースケースを先頭**に。skill 一覧はコンテキストウィンドウの約 1% の文字数予算を持ち、超過すると**使用頻度の低い skill から description が落ちて**ルーティング精度が下がる。
- **T8（肯定形・理由付き）**: 制約には理由を添える。`〜するな` より `〜する` の形で書く。

### 維持リスト（K: 変更しない）

- 安全ガード（`Never modify source files` 等）
- TDD 規律（「すべての実装はテストから」）
- 具体的で有効なルール（marp の文字数制限等）
- ファイルパス `L{number}` 形式の強制
- 本質的価値としての並列 subagent 設計（`/review`・`/implement`）
- **`Skill` ツール連鎖・subagent preload の被呼び出し skill の起動可能性**（下記「起動制御」参照）

### モデル依存記述の集約

モデルバージョンに依存する設計判断は**本節に集約**する。モデル更新時はここだけを更新すればよい構造を保つ。個別の skill / reference に `## 設計思想（{model} baseline）` のような節を作らない。

## 起動制御フィールドの選び方

`description` は skill 一覧に常駐するため、使わない skill を隠すと budget が空く。ただし**隠し方を誤ると呼び出しが壊れる**。

| 設定 | Claude から呼べる | `/` メニュー | listing の description |
|------|------------------|-------------|----------------------|
| （未指定） | 可 | 表示 | 載る |
| `user-invocable: false` | **可** | 非表示 | **載る**（budget は減らない） |
| `disable-model-invocation: true` | 不可 | 表示 | **載らない** |
| 両方 | **不可** | 非表示 | 載らない |
| `skillOverrides: "user-invocable-only"`（settings） | 不可 | 表示 | 載らない |
| `skillOverrides: "off"`（settings） | 不可 | 非表示 | 載らない（**フルネーム呼び出しもエラー**） |

判断の指針:

- **budget を空けたいだけなら `disable-model-invocation: true`**。`/名前` は残るので可逆性が高い。
- **`user-invocable: false` は budget 対策にならない**。用途は「ユーザーが直接叩く意味がない背景知識」を `/` メニューから隠すことだけ。
- **repo 管理外の skill は frontmatter を持てない**ため `settings.json` の `skillOverrides` を使う。
- **plugin 由来の skill に `skillOverrides` は効かない**。`/plugin` で plugin ごと有効/無効を切り替える。

### `disable-model-invocation` を付けてはいけない skill

このフィールドは **Claude の自動起動・`Skill` ツールからのプログラム的呼び出し・subagent への preload・scheduled task 起動のすべてをブロック**する。以下は被呼び出し側なので付けない:

| skill | 呼び出し元 |
|-------|-----------|
| `fix` / `plan-lgtm` | `fix-lgtm`, `fix-lgtm-implement` |
| `implement` | `fix-lgtm-implement` |
| `review-plan` / `revise` | `plan-lgtm` |
| `strategic-ddd` | `strategic-ddd-designer` subagent の `skills:` preload |

新たに付与する前に、呼び出しグラフを再確認する:

```bash
# リポジトリルートで実行する。バッククォート囲みだけを見ると
# 「Skillツールで明示ロード」のような表記揺れと reference/ 配下を取りこぼす
grep -rniE 'Skill[[:space:]]*(ツール|tool)' claude/skills/   # skill 間のプログラム的呼び出し
grep -rn '^skills:' claude/subagents/                        # subagent への preload
```

scheduled task から repo skill を回している場合は `/schedule` の一覧も確認する（`disable-model-invocation` は scheduled task 起動もブロックする）。

**progressive disclosure を目的とする skill には付けない。** description が listing にあるからこそ Claude が必要時にロードできる仕組みであり、隠すと目的を果たせない。

## ファイル追加規約

### Skills の追加

1. `claude/skills/<skill-name>/SKILL.md` を作成（YAML frontmatter に `name` と `description` 必須）
2. `./setup.sh install` を再実行
3. `./claude/scripts/verify-skills.sh` で構造検証

補助ファイル（テンプレート、参考資料、検証スクリプト等）は同じ skill ディレクトリ内に配置する（例: `claude/skills/design/reference/plan-template.md`）。**本文が長い skill は `reference/` に切り出し、「読むタイミング」を表で示す**（`claude/skills/review/SKILL.md` の冒頭が実例）。表は「必ず読む」と「条件付きで読む」の 2 段に分ける — 起動したら必ず通るフェーズのものを条件付きと並べると、「該当する場合のみ読む」という規約の意味が薄れる。

注意点:

- **ディレクトリ名が起動名**になる。frontmatter の `name` と一致させる（不一致でも動くが `skillOverrides` のキー指定で事故になる）。
- `description` にトリガー語（`時に` / `する時` / `使用` / `呼び出` / `キーワード` / `トリガー` / `when` / `trigger` / `use this` / `use when`）を含める。`hook-lint-skill-frontmatter.sh` が検査する。
- **`~/.claude/skills/` は「最後に `./setup.sh install` を実行したチェックアウト」を指す symlink。** どれが効いているかは `ls -l ~/.claude/skills/<name>` で確認する。worktree から install すると未マージの内容が全プロジェクトのランタイムに即時適用され、その worktree を削除すると skill symlink と `~/.claude/settings.json` がまとめて dangling になる。**install はメインチェックアウトから実行する。**
- install 元と異なるチェックアウトから `verify-skills.sh` を実行すると check 1/3 が FAIL する。**FAIL したらまず install 元を確認する**（skill の内容不備とは限らない）。

### SubAgents の追加

1. `claude/subagents/<category>/` 配下に `.md` ファイルを作成
2. `./setup.sh install` を再実行
3. `README.md` はセットアップスクリプトがスキップするため、ドキュメント用に使用可
