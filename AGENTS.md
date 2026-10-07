# AGENTS.md

このファイルは、この repo で作業する Claude Code と Codex の両方が読む指示の正本。`CLAUDE.md` は本ファイルへの symlink で、Claude Code は `CLAUDE.md` として、Codex は `AGENTS.md` として同じ内容を読む。

## プロジェクト概要

Claude Code と Codex で使用する Skills、SubAgents のコレクション。すべてのプロジェクトで共通利用するための拡張機能を管理するリポジトリ。コードの実装はなく、プロンプト（Markdown）の管理が主目的。


## セットアップ

```bash
./setup.sh install                  # Scripts は実体コピー、Skills・Agents・settings.json は symlink
./setup.sh install --prune-scripts  # 上記に加え、repo に無い ~/.claude/scripts/ の orphan を退避して削除
./setup.sh status                   # インストール状態の確認
./setup.sh uninstall                # インストールしたものを撤去
./setup.sh migrate                  # 旧形式 (commands→skill 化されたディレクトリ・旧配置先の subagent リンク) を撤去し、旧 claude/ を指す skills・agents のリンクを shared/ へ張り替える（Claude 側のみ）
```

**他端末への展開時の手順**: `git pull && ./setup.sh migrate && ./setup.sh install`

**ディレクトリの役割**: 共通資産（skills・agents・scripts・global-rules.md）は `shared/` が正本。`claude/` に残るのは Claude Code 固有の `settings.json` と、旧パス `claude/{skills,agents,scripts}` を解決する互換 symlink（`→ ../shared/…`。移行期間用で、後続の PR で削除する）だけ。Codex 固有のもの（読み替え表 `codex-rules.md`・agents の TOML 生成器 `gen-agents.py`）は `codex/`。新しいファイルは `shared/` に置く。

配置方式は 2 通り（`~/.codex` が在れば、Codex にも同じ資産を展開する。3 つ目の方式ではなく、下の 2 方式の Codex 版）:

- **skills / agents / settings.json**: symlink。repo の更新が即座に反映される
  - **subagent 定義は `shared/agents/<カテゴリ>/` に一本化している。** Claude Code がユーザーレベルの subagent を読み込むのは `~/.claude/agents/` だけで、サブフォルダも再帰的に読み、識別子は frontmatter の `name` で決まる
  - setup.sh はファイルを basename で `~/.claude/agents/` に平置きの symlink にするので、`name` とファイル名を一致させ、ツリー全体で一意にする
  - `~/.claude/agents/` を初めて作った install の後は、セッションを開き直すまで読み込まれない。旧配置先 `~/.claude/sub-agents/`（読み込まれない）のリンクは `./setup.sh migrate` が撤去する
- **scripts**: 実体コピー。**`shared/scripts/` を編集・pull したら `./setup.sh install` を再実行する。** 忘れても hook は「失敗」せず**古いスクリプトで静かに動き続ける**。symlink をやめたのは、メインチェックアウトがスクリプトを含まないブランチにある間に解決できず全 hook が exit 127 になるため。exit 127 は non-blocking なのでガードレールは「止まる」のではなく**開く**

- **Codex**（`~/.codex` が在るとき。無ければ省略し、`~/.codex` は作らない）: skills は `~/.agents/skills/<name>` への symlink（同名の他者の実体・リンクには触れず warn。`~/.agents/skills` は他のツールも書き込む共有の場所）、agents は install 時に `.md` から TOML を**生成**して `~/.codex/agents/` へ（手書きの TOML には触れない。**`shared/agents/` を編集したら `./setup.sh install` を再実行する**。scripts と同じく、忘れても古い物が静かに動き続ける）、規約は `~/.codex/AGENTS.md` のマーカーブロック 2 つ（共通規約と、Codex 専用の読み替え表 `codex/codex-rules.md`）、hook は `~/.codex/hooks.json` の自前エントリだけ。変わったら Codex の `/hooks` で信頼し直す。詳細は README の「Codex で使うときの注意」

**install はメインチェックアウトから実行する。** settings.json と skills は symlink のままなので install 元のチェックアウトを全プロジェクトのランタイムが参照する。worktree から install すると、その worktree を削除した瞬間に deny リスト・hook 定義・全 skill・`~/.claude/agents/` の subagent がまとめて失われる（hook と違って何も失敗しないので気づけない）。linked worktree から実行すると `./setup.sh install` が警告する。

構造的検証は `./shared/scripts/verify-skills.sh`（fail があれば exit 1、warn のみなら exit 0。check 4 が scripts の同期・orphan・install 元を、check 5 が listing budget を見る。Codex 側は check 8（skills）・9（暗黙起動の抑止）・10（TOML の同期）・11（AGENTS.md のブロックとサイズ）・12（hooks.json の位置と信頼）、7(1) が `decide_ask_or_deny` の複製と「自分のリンク」・マーカーの並びの判定の本体の一致を見る）。

**ガードレールの挙動検証は `bash shared/scripts/tests/test-guardrails.sh`（`shared/scripts/` を編集したら実行する）。** 対象はいずれも fail-open 型（ガードが黙って開く / error が黙って消える）で、壊れても何も起きないため通常の動作確認では検知できない。Claude Code の入力と Codex の入力（`turn_id` あり）の両方を検査する。CI が無い本リポジトリでは、このテストが回帰を捉える唯一の手段になる。`./shared/scripts/verify-skills.sh --with-behavior-tests` からも呼べる。`setup.sh` と `verify-skills.sh` の**配置処理**（リンク先・実体コピー・前回 sha の判定）は、sandbox HOME で実プロセスを走らせる `bash shared/scripts/tests/test-setup-codex.sh` が検証する（`setup.sh` を編集したら実行する）。

### settings.json のリポジトリ管理（Claude Code 固有）

`~/.claude/settings.json` は repo 内 `claude/settings.json` への symlink として管理する。Git 履歴で変更追跡 + `git restore` でロールバック可能。`./setup.sh install` が冪等に symlink を再構築する。

### env-var indirection パターン（機微情報の正規取り扱い。Claude Code の settings.json）

本リポジトリは **PUBLIC** リポジトリ。`claude/settings.json` にリテラルな API キー / トークン / シークレットを書くことは**禁止**。

**ルール**:

- 機微情報は `~/.zshrc` で `CLAUDE_CODE_{用途}_{種別}` 形式の環境変数として `export`
- 子プロセスへの注入が必要なら `OTEL_EXPORTER_OTLP_HEADERS` 等の最終形変数も `~/.zshrc` で `export`（Claude Code は settings.json `env` 内の `${VAR}` 展開を**非サポート**）
- `claude/settings.json` には機微情報を含めない

**例**:

```bash
# ~/.zshrc
export CLAUDE_CODE_TELEMETRY_DD_API_KEY=<datadog-api-key>
export OTEL_EXPORTER_OTLP_HEADERS="DD-API-KEY=$CLAUDE_CODE_TELEMETRY_DD_API_KEY"
```

新規 commit 時は `git diff --cached claude/settings.json | grep -iE '[a-f0-9]{32}|key=[a-zA-Z0-9]{20,}' | grep -v '\${'` が 0 件であることを確認する。

### deny リストの判断記録（Claude Code 固有。settings.json はコメントを書けないためここに置く）

`"defaultMode": "bypassPermissions"` かつ `"skipDangerousModePermissionPrompt": true` のため、allow / ask は実質機能せず **`deny` がほぼ唯一の実効ガード**。deny からパターンを外すときは理由をここに残す。

- **AWS 資格情報**: `Read/Edit(**/.aws/**)` と `Read/Edit(**/*credentials*)` で保護する。`*aws*` の全面 deny は `aws-cdk-lib` / `aws-sdk` 等の通常のソースファイルに誤爆するため採らない。`~/` 表記は permission パターンで展開されるかを実測していないため、パス基準の `**/.aws/**` を使う
- **誤爆したとき**: `bypassPermissions` 下では deny にマッチした操作は確認プロンプトなしでブロックされる（ask へのフォールバックがない）。`~/.claude/settings.local.json` で一時的に上書きするか、`claude/settings.json` の該当パターンを外す
- **subagent の誤委譲**: 有効な subagent の description は常時コンテキストに載り、自動委譲の候補になる。事前に機械的に止める手段は無いので、誤委譲や意図しない書き換えを観測したら `Agent(<name>)`（plugin は `Agent(<plugin>:<name>)`）を deny に足して止める。現時点では足していない
- **Bash 経路は塞いでいない**: `Bash(cat:*)` / `Bash(grep:*)` が allow のため `cat ~/.aws/credentials` は通る。deny は Read/Edit ツール経路の defense-in-depth であり、完全な封鎖ではない
- **deny の実効性は未確認（2026-07-27 実測）**: scratchpad 配下に `.aws/credentials` を作って Read したところ **ブロックされずに読めた**（`Read(**/.aws/**)` が deny にあるにもかかわらず発火しない）。ただし scratchpad は権限チェックが緩和されている可能性があり、repo 内での再検証は permission により実施できなかったため、**「deny が機能していない」と断定はできない**。この前提が確認できるまで、deny パターンの調整（`**/*credentials*` が `credentials.ts` 等に誤爆する / `aws-exports.js` が保護外になる、という指摘）は**保留する** — 発火しないパターンを変えても保護は増えず、誤爆リスクだけが増えるため。実効性の確認が先

### hook 登録の判断記録（Claude Code 固有。settings.json にコメントを書けないため）

`hook-block-local-contract-link.sh`（PreToolUse / Bash）: 依存宣言が `link:` / `file:` のままの `package.json` を staged にした `git commit` を `ask` にする。

- **パッケージ名もリポジトリパスも持たない汎用パターン**にした。settings.json は PUBLIC リポジトリにコミットされるため引数にパスを書けず、Claude Code は settings.json `env` の `${VAR}` 展開を非サポートなので環境変数でも渡せない。汎用にすると適用範囲も広がる（pnpm workspace は `workspace:` を使うので、コミットされた `link:` / `file:` はほぼ常に事故）
- **`deny` ではなく `ask`**。`file:` を正規に使うリポジトリでの誤爆に備える（`bypassPermissions` 下では deny は確認プロンプトなしでブロックされる）
- **足切り（基点に `pnpm-lock.yaml` が無ければ素通し）を fail-closed より前に置く**。逆順だと変数展開を含む commit が pnpm 非使用リポジトリでも `ask` になり、**本リポジトリ自身が該当する**。日常的に出る ask は「中身を読まずに承認する習慣」を育て、fail-open とは別方向で同じくガードを無効化する
- **第一ガードは hook ではない**。`link-contract.sh` が張る `git update-index --skip-worktree` が経路を問わず巻き込みを防ぎ、hook は 2 枚目（Bash 経路のみ。Codex の `workdir` と wrapper 経由の commit は素通し）

### hook の判断記録（Codex）

`~/.codex/hooks.json` の自前エントリ（command が `/.claude/scripts/` を含む hook）は、`claude/settings.json` から生成する。定義の正本は 1 か所。

- **自前グループは各イベントの先頭に固定する。** Codex の hook の信頼は `config.toml` の `[hooks.state."<hooks.json の絶対パス>:<event の snake_case>:<グループ index>:<hook index>"]` で、位置が 1 つずれると中身が同じでも「要レビュー」になりスキップされる（= ガードが黙って開く）。Orca・Muxy のグループは自前グループの後ろに居るので、先頭を同じ数で差し替えれば位置は動かない（実機の並びなら初回の install から書き込まない）。数が変わるときだけ、そのイベントの全件を `/hooks` で信頼し直す（install が案内する）。先頭以外に自前の hook があるときは、推測で並べ替えず失敗する
- **Codex では `ask` を `deny` に変える。** Codex は確認プロンプトに未対応で、未対応の値は hook の失敗として扱われ操作が続行する。入力に `turn_id` があれば Codex（Claude Code の入力には無い）。判定は各 hook に複製した `decide_ask_or_deny` で行い、共通ファイルは `source` しない（`source` の失敗は exit 2 以外になりガードが開く）。複製の欠落・本体の不一致と、関数を通さない ask の直書きは verify の check 7(1) が検知する。理由には `[要確認]` を付け、モデルはユーザーに確認して、ユーザー自身に実行してもらう（SKILL.md の lint の frontmatter の deny は、直した内容で再実行する）
- **`apply_patch` で書かれる SKILL.md も lint する。** Codex は SKILL.md を Write / Edit ではなく `apply_patch` で編集し、入力に `file_path` が無い（patch 本文は `tool_input.command`）。以前は lint が黙って開いていた。patch の書式は Codex 0.160.0 に同梱の文法に従い、patch を解釈できないとき・現ファイルに当てられないときは、SKILL.md に触れる疑いがあれば止める（fail-closed）
- **未確定（G-1）: 信頼ハッシュがスクリプトの中身を含むか。** 含む場合、scripts を更新すると信頼が外れて hook がスキップされる。実測するまで、install は自前 hook が指すスクリプトを更新したら `/hooks` の確認を案内し、verify の check 12 は mtime の比較を INFO に留める

### portability 課題（Claude Code 固有。F-7 で対応予定）

`claude/settings.json` には個人固有絶対パス（mise の Node 絶対パス、`statusLine.command` の絶対パス等）が含まれる。別端末への展開は F-7 解決まで非対応。

## 主要ワークフロー（Skills）

Skills は開発ワークフローの各ステップを担う。**下図の矢印は手順の順序であり、自動で流れるパイプラインではない** — 各ステップは `/<skill-name>` で明示的に呼び出す。`/grill` が Phase 0 で業務シナリオ（`tmp/scenario.md`）を確立し、`/design` フェーズ 1.2 はそれが無かった場合のフォールバックとして働く:

### 簡易フロー（新規仕様の追加）

```
/ask → /grill → /design → /spec-check → /review-plan ⇄ /revise → /implement
  → /review → /fix → /implement fix-plan → /spec-archive → /create-pr
```

### 完全フロー（既存仕様の修正）

```
/ask → /grill → /design → /spec-check → /review-plan ⇄ /revise → /implement
  → /review → /fix → /implement fix-plan → /spec-propose → (レビュー) → /spec-archive {change-name} → /create-pr
```

主要 skill は `shared/skills/` 配下、`/<name>` で呼び出し。詳細は各 SKILL.md および `./setup.sh status` で確認できる。

### 自然言語では起動しない skill

`disable-model-invocation: true` を付けた skill は **`/` 呼び出しのみ**で、自然言語からは起動しない（一覧: `grep -l '^disable-model-invocation: true' shared/skills/*/SKILL.md | xargs -n1 dirname | xargs -n1 basename`）。

**無反応で終わるのではなく、有効な別実装に流れる**点に注意する。例: 「worktree を掃除して」は `worktree-cleanup` ではなく commit-commands plugin の `clean_gone` に吸われ、claude-context index の `clear_index` 回収が行われずに collection が孤児化する。`/worktree-cleanup` と明示すること。

## Skills 共通規約

本リポジトリの全 skill には以下の規約を適用する。**各 SKILL.md では詳細を再宣言せず、`**規約**: …` のようなマーカー行も置かない**（本ファイルは常時ロードされるため、56 skill に同じ 1 行を置くのは重複でしかない）:

- 出力は日本語（技術用語・コード例は英語のまま）
- `tmp/` 配下のファイルはコミットしない
- レビュー指摘・コード参照は `file_path:L{number}` 形式
- ソースコードを変更しない skill は、出力先を skill 本文に明記する（例: `./tmp/research.md`）
- 成果物を人が読む形にする場合、完了報告に続けて **HTML 化を提案する（既定）**。`html-view` で `tmp/<basename>.html` を生成してブラウザで開く。提案は**完了報告時に 1 回だけ**行い、同一実行内で再提案しない。Artifact（claude.ai 上の共有ページ）は、**ユーザーが共有を求めたときだけ**使う。その場合は `artifact-design` skill に従い、`html-view` の reference は参照しない（設計指針を二重管理しないため）。HTML はローカルのファイルで、Claude Code と Codex のどちらでも同じ手段で作れる
  - **例外: `grill`** — 進行中の全体感を共有することが目的のため、**Phase 0 の完了時に 1 回提案し、以後は決定が入るたびに `tmp/grill.html` を更新する**（提案は 1 回で、更新は提案ではない）。Phase 0 完了時点の表示対象は `tmp/scenario.md` の業務シナリオで、`tmp/grill.md` の 4 ブロックは以後の手順で埋まる
- **`tmp/` の成果物を黙って上書きしない**: skill の開始時点で既に存在し、かつ skill 本文にその扱い（追記・resume・作り直し・上書き/追記/キャンセルの確認）が書かれていなければ、書き出す前に上書き / 追記 / キャンセルを確認する。判定は「開始時に存在するか」だけで行い、どのセッションが作ったかは判断しない（Claude Code と Codex を同じ worktree で行き来すると互いの成果物が残り、作成者の判断はモデルごとに割れるため）
  - **上書きが契約の skill は対象外**: `revise`（対象計画を上書きし、旧版を archive に残す）、`review-plan`（`tmp/plan-review.md` を毎回作り直す。`plan-lgtm` がそのファイルの mtime で完了を判定する）、`review`（`tmp/review/` を作り直す）。これらは本文で扱いを決めている

> skill / subagent を書くときのプロンプト規約（Claude 5 向けの変換ルール T1–T8、維持リスト K、起動制御フィールドの選び方、追加手順）は `shared/skills/skill-authoring/SKILL.md` に集約している。

## OpenSpec（仕様管理）

```
openspec/
├── config.yaml                  ← プロジェクト固有の設定（任意）
├── specs/                       ← 仕様の正（Single Source of Truth）
│   └── {domain}/spec.md
└── changes/                     ← 変更提案（作業領域）
    ├── {change-name}/
    │   ├── proposal.md          ← Why / What Changes / Impact
    │   ├── specs/{domain}/spec.md  ← delta spec (ADDED/MODIFIED/REMOVED/RENAMED)
    │   ├── design.md            ← 技術設計
    │   └── tasks.md             ← 実装ステップ
    └── archive/                 ← 完了した変更
```
