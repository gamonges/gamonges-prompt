---
name: skill-authoring
description: skill / subagent を新規追加・編集する時の規約。Claude 5 向けのプロンプト変換ルール（T1–T8）、起動制御フィールドの選び方、追加手順。`/skill-authoring` 呼び出しでも使用。
---

本リポジトリの skill / subagent を書くときの規約。**Skills 共通規約（出力言語・`tmp/` の扱い・`L{number}` 形式）は `AGENTS.md`（`CLAUDE.md` はその symlink）にあり、ここでは再宣言しない。**

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

**この表が起動制御の正本。** `_template/SKILL.md` と `_template/reference/skill-frontmatter-spec.md` は本表を参照し、説明を複製しない（複製すると必ず片方がずれる）。

| 設定 | Claude から呼べる | `/` メニュー | listing の description |
|------|------------------|-------------|----------------------|
| （未指定） | 可 | 表示 | 載る |
| `user-invocable: false` | **可** | 非表示 | **載る**（budget は減らない） |
| `skillOverrides: "name-only"`（settings） | **可** | 表示 | **name のみ**（description 分が空く） |
| `disable-model-invocation: true` | 不可 | 表示 | **載らない** |
| 両方 | **不可** | 非表示 | 載らない |
| `skillOverrides: "user-invocable-only"`（settings） | 不可 | 表示 | 載らない |
| `skillOverrides: "off"`（settings） | 不可 | 非表示 | 載らない（**フルネーム呼び出しもエラー**） |

判断の指針:

- **budget 対策の第一選択は `skillOverrides: "name-only"`**。description 分が空くうえ、`Skill` ツール呼び出し・subagent preload・自然言語起動のすべてが生き残る。「budget を空ける」と「呼び出しを壊さない」を二者択一にしない。
- **`disable-model-invocation: true` はどこからも呼ばれない終端 skill にのみ使う**。下記のとおり全起動経路をブロックするため、被呼び出し側に付けると連鎖が黙って壊れる。
- **`user-invocable: false` は budget 対策にならない**。用途は「ユーザーが直接叩く意味がない背景知識」を `/` メニューから隠すことだけ。
- **repo 管理外の skill は frontmatter を持てない**ため `settings.json` の `skillOverrides` を使う。
- **組み込み skill には `skillOverrides` が効く**。実測: `find-skills`（組み込み）に `user-invocable-only` を付けると listing から消え、キーを外すと復活した。repo 管理外の skill を budget から外す正規の手段。
- **plugin 由来の skill に `skillOverrides` は効かない**。`/plugin` で plugin ごと有効/無効を切り替える。
- `verify-skills.sh` の check 5 は「repo skill に存在しないキー」を **INFO** で報告する。組み込み skill を隠す正当な設定と、キー名のタイポで黙って無効になっている状態を機械的に区別できないため、warn にはしない（正当な設定で常時点灯させると検出力を失う）。心当たりのないキーが出たらタイポを疑う。

### `disable-model-invocation` を付けてはいけない skill

このフィールドは **Claude の自動起動・`Skill` ツールからのプログラム的呼び出し・subagent への preload・scheduled task 起動のすべてをブロック**する。以下は被呼び出し側なので付けない:

| skill | 呼び出し元 |
|-------|-----------|
| `fix` / `plan-lgtm` | `fix-lgtm`, `fix-lgtm-implement` |
| `implement` | `fix-lgtm-implement` |
| `review-plan` / `revise` | `plan-lgtm` |
| `strategic-ddd` | `strategic-ddd-designer` subagent の `skills:` preload |
| `stack-pr-init` / `stack-pr-add` | `create-pr`（Phase 0 の分岐） |
| `verify-scenario` | `implement`（Phase 4 の条件付き実行） |
| `test-audit` | `test-auditor` subagent の `skills:` preload / `implement`（`reference/test-audit-flow.md` の作用点） |

新たに付与する前に、呼び出しグラフを再確認する:

```bash
# リポジトリルートで実行する。`Skill` ツール のようにバッククォートが挟まる表記が実際には
# 多数派なので、パターン側で許容しないと被呼び出し skill を取りこぼす（実測 3 hit → 16 hit）
grep -rniE '`?Skill`?[[:space:]]*(ツール|tool)' shared/skills/ shared/agents/
grep -rn '^skills:' -A3 shared/agents/     # subagent への preload（skill 名は次の行以降）
```

scheduled task から repo skill を回している場合は `/schedule` の一覧も確認する（`disable-model-invocation` は scheduled task 起動もブロックする）。

**progressive disclosure を目的とする skill には付けない。** description が listing にあるからこそ Claude が必要時にロードできる仕組みであり、隠すと目的を果たせない。

## ファイル追加規約

### Skills の追加

1. `shared/skills/<skill-name>/SKILL.md` を作成（YAML frontmatter に `name` と `description` 必須）
2. `disable-model-invocation: true` を付けたら、同じ skill に `agents/openai.yaml`（`policy:` の下に `allow_implicit_invocation: false` の 2 行）も置く。Codex は frontmatter のこのフィールドを読まず、自然文での暗黙起動を止めるのはこのファイルだけ（`verify-skills.sh` の check 9 が過不足を検査する）
3. 入力ファイル（既定 `./tmp/context.md`）で質問・要件を受け取る skill は、入口を `../brief/reference/entry.md` に従わせる（質問を文章や会話の依頼で渡されたときも同じ手順に入れるため。`verify-skills.sh` の check 2(b) が、文言「省略時は `./tmp/context.md`」で見つけた skill の参照漏れを検査する）
4. `./setup.sh install` を再実行
5. `./shared/scripts/verify-skills.sh` で構造検証

補助ファイル（テンプレート、参考資料、検証スクリプト等）は同じ skill ディレクトリ内に配置する（例: `shared/skills/design/reference/plan-template.md`）。**本文が長い skill は `reference/` に切り出し、「読むタイミング」を表で示す**（`shared/skills/review/SKILL.md` の冒頭が実例）。表は「必ず読む」と「条件付きで読む」の 2 段に分ける — 起動したら必ず通るフェーズのものを条件付きと並べると、「該当する場合のみ読む」という規約の意味が薄れる。

注意点:

- **ディレクトリ名が起動名**になる。frontmatter の `name` と一致させる（不一致でも動くが `skillOverrides` のキー指定で事故になる）。
- `description` にトリガー語（`時に` / `する時` / `使用` / `呼び出` / `キーワード` / `トリガー` / `when` / `trigger` / `use this` / `use when`）を含める。`hook-lint-skill-frontmatter.sh` が検査する。
- **`~/.claude/skills/` は「最後に `./setup.sh install` を実行したチェックアウト」を指す symlink。** どれが効いているかは `ls -l ~/.claude/skills/<name>` で確認する。worktree から install すると未マージの内容が全プロジェクトのランタイムに即時適用され、その worktree を削除すると skill symlink と `~/.claude/settings.json` がまとめて dangling になる。**install はメインチェックアウトから実行する。**
- install 元と異なるチェックアウトから `verify-skills.sh` を実行すると check 1/3 が FAIL する。**FAIL したらまず install 元を確認する**（skill の内容不備とは限らない）。

### SubAgents の追加

1. `shared/agents/<category>/` に `.md` ファイルを作成する（配置と再起動の要否は `AGENTS.md` のセットアップ節）
2. `./setup.sh install` を再実行（Codex には install 時に `.md` から TOML を生成して置くので、**`.md` を編集したら再実行しないと古い TOML が残る**）
3. `README.md` はセットアップスクリプトがスキップするため、ドキュメント用に使用可

注意点:

- **Codex に渡るのは frontmatter の `name`・`description`・`tools`・`skills` だけ**（生成器 `codex/gen-agents.py`）。`tools` に Write・Edit・MultiEdit・NotebookEdit が無い agent は `sandbox_mode = "read-only"` になり（判定役がこれに当たる）、`tools` が無い agent は親を継承する。それ以外の `tools` の制限（例: WebSearch の有無）と `model:` は Codex に渡らない。`skills:` は本文の先頭で SKILL.md を読ませる指示に変換される（preload が無いので）。未知のキー・name とファイル名の不一致・Codex の組み込み agent（`default`・`worker`・`explorer`）と同じ name は生成がエラーになる
- **frontmatter の `name` をファイル名と一致させ、`shared/agents/` 全体で一意にする。** Claude Code は `name` で識別し、setup.sh は basename で平置きの symlink を張る。どちらかが重複すると、片方が黙って読まれなくなる
- **判定役（`name` が `-reviewer` / `-auditor` / `-tester` で終わるもの）は、`tools` に Write / Edit を持たせない。** main が `bypassPermissions` のとき subagent も同じモードで動くので、判定役が確認なしでファイルを書き換えられてしまう
- **外部の subagent 集から取り込むときは、存在しない agent への照会・通知の手順を持ち込まない**（`context-manager` への問い合わせ、エージェント間の状態通知の JSON、他 agent との連携の列挙など）。subagent は Agent ツールを持たないので他の agent を呼べず、手順が空振りするだけになる
