# Claude Skills & SubAgents Collection

Claude Code と Codex で使用するための Skills と SubAgents のコレクションです。

## 概要

このリポジトリには、すべてのプロジェクトで共通して使用できる Claude の拡張機能が含まれています。

### 📁 構成

```
shared/                  # 共通資産（正本）。Claude Code と Codex の両方がここを参照する
├── agents/              # subagent 定義（~/.claude/agents/ へ配置。Claude Code はサブフォルダも再帰的に読む）
│   ├── 01-core-development/     # コア開発
│   ├── 02-language-specialists/ # 言語スペシャリスト
│   ├── 03-infrastructure/       # インフラ
│   ├── 04-quality-security/     # 品質・セキュリティ
│   ├── 05-business-analysis/    # 業務分析
│   └── 06-architecture/         # アーキテクチャ
├── skills/              # エージェント スキル（SKILL.md 必須、frontmatter に name と description 必須）
│   ├── ask/
│   ├── design/
│   ├── implement/
│   ├── review/
│   └── ...
├── scripts/             # ユーティリティスクリプト・hook
│   ├── statusline.py
│   ├── sync-cursor-skills.sh
│   └── verify-skills.sh
└── global-rules.md      # 全プロジェクト共通の規約（~/.claude/CLAUDE.md と ~/.codex/AGENTS.md にマーカーブロックで配置）

claude/                  # Claude Code 固有
└── settings.json        # hook 定義・deny リスト等（~/.claude/settings.json へ symlink）

codex/                   # Codex 固有
├── codex-rules.md       # Codex 専用の読み替え表（~/.codex/AGENTS.md にマーカーブロックで配置）
├── gen-agents.py        # agents の .md から Codex の TOML を生成する（setup.sh と verify-skills.sh の check 10 が使う）
└── verified-codex-version  # 信頼ハッシュ・apply_patch の文法を確かめた Codex の版（verify-skills.sh の check 13 が今の版と比べる）
```

> **注**: Anthropic 公式により Custom Commands は Skills に統合されました（出典: https://code.claude.com/docs/en/custom-skills.md ）。本リポジトリでも旧 `claude/commands/` を廃止し、すべて `shared/skills/<name>/SKILL.md` 形式に統一しています。

## 🚀 セットアップ

### インストール

リポジトリをクローンして、セットアップスクリプトを実行します：

```bash
git clone <repository-url>
cd gamonges-prompt
./setup.sh install
```

これにより、以下の場所に配置されます。`~/.codex` が在れば Codex にも展開されます（無ければ省略し、`~/.codex` は作りません）：

| 資産 | Claude Code | Codex |
|------|-------------|-------|
| Skills | `~/.claude/skills/<name>`（symlink。repo の更新が即座に反映される） | `~/.agents/skills/<name>`（symlink）。同名の他者の実体・リンクには触れず warn する |
| Agents | `~/.claude/agents/`（symlink。`shared/agents/<カテゴリ>/` の定義を basename で平置きにする。ユーザーレベルの subagent を読み込む場所） | `~/.codex/agents/<name>.toml`（**install 時に `.md` から生成**。**`shared/agents/` を編集したら `./setup.sh install` を再実行する**。手書きの TOML には触れない） |
| 共通規約 | `~/.claude/CLAUDE.md` のマーカーブロック | `~/.codex/AGENTS.md` のマーカーブロック 2 つ（共通規約と、Codex 専用の読み替え表 `codex/codex-rules.md`） |
| Hook | `~/.claude/settings.json`（symlink）の定義が `~/.claude/scripts/` を実行する | `~/.codex/hooks.json` の**自前エントリだけ**（各イベントの先頭のグループ。Muxy・Orca の位置は動かさない）。変わったら Codex の `/hooks` で信頼し直す（効かない経路は「Codex で使うときの注意」） |
| settings.json | `~/.claude/settings.json`（symlink） | — |
| Scripts | `~/.claude/scripts/`（**実体コピー**。編集・pull したら `./setup.sh install` を再実行する） | （共通。Codex の hook も同じスクリプトを実行する） |

install が失敗したとき・並行して実行したとき:

- `~/.claude/CLAUDE.md` の共通規約と、Codex 側の各段（hooks.json → skills → agents → `~/.codex/AGENTS.md` の順）は、1 つが失敗しても残りの段を最後まで実行し、最後に失敗した段の一覧を出して exit 1 で終わる（完了メッセージは出ない。理由は各段の ✗ の行にある）。hooks.json を最初に置くのは、他の段の失敗で Codex のガードが入らないままにしないため。それより前の scripts・skills・agents・settings.json の配置で失敗したときは、その場で止まる
- 次のときは、そのファイルに何も書き込まずに段を失敗させる（uninstall は同じ場合に撤去せず warn する）: 読めない、またはマーカーの並びが「BEGIN 行 1 つ・その後ろに END 行 1 つ」でない `~/.claude/CLAUDE.md`・`~/.codex/AGENTS.md`（BEGIN 以降を消さないため。手で直す）、空・JSON のオブジェクトでない `~/.codex/hooks.json`、読んだ後に他のツール（Codex・Orca・Muxy）が書き換えた hooks.json（もう一度 install する）、hooks.json に自前 hook が残っているのに自前 hook を 1 本も含まない `claude/settings.json`（撤去は uninstall の役目）
- install・uninstall・migrate は `~/.claude/.setup.lock` で直列化する（status は取らない）。実行中に別の setup.sh を起動すると、後の方が PID を出して止まる。強制終了（SIGKILL 等）の後にロックが残ったら、他に setup.sh が動いていないことを確かめてから `rm -rf ~/.claude/.setup.lock` で消す（自動では奪わない）

### 状態確認

```bash
./setup.sh status
```

### 検証

```bash
./shared/scripts/verify-skills.sh   # SKILL.md 数 / frontmatter (name とディレクトリ名の一致) /
                                    # symlink / scripts の同期・orphan・install 元 / listing budget /
                                    # disable-model-invocation と agents/openai.yaml の一致 /
                                    # Codex 側（~/.codex があるとき）の skills・agents・AGENTS.md・hooks.json の同期と位置
                                    # fail があれば exit 1、warn のみなら exit 0
```

テスト（CI が無いので手で回す）:

```bash
bash shared/scripts/tests/test-guardrails.sh     # hook の挙動（Claude Code・Codex の両入力）。shared/scripts/ を編集したら
bash shared/scripts/tests/test-setup-codex.sh    # setup.sh・verify・agents の TOML 生成の挙動（sandbox HOME）。setup.sh や codex/ を編集したら
```

### アンインストール

```bash
./setup.sh uninstall
```

### 旧形式からの移行（他端末で旧バージョンを install していた場合）

```bash
git pull
./setup.sh migrate    # 旧形式 (commands→skill 化されたディレクトリ・旧配置先 ~/.claude/sub-agents/ のリンク) を撤去し、
                      # 旧 claude/ を指す skills・agents のリンクを shared/ へ張り替える（Claude 側のみ。Codex 側には触れない）
./setup.sh install    # 新形式で再インストール
```

### Codex で使うときの注意

- **skill は `$name` で呼ぶ**（Claude Code の `/name` に当たる）。skill・agent の本文は Claude Code の語彙（`/name`・`AskUserQuestion`・`Skill` ツール等）で書かれており、`~/.codex/AGENTS.md` に入る読み替え表（`codex/codex-rules.md`）が Codex 向けに読み替える
- `disable-model-invocation: true` の skill は、Claude Code では `/` 呼び出しのみ。Codex では frontmatter のこのフィールドが効かないので、skill ごとの `agents/openai.yaml`（`policy: allow_implicit_invocation: false`）で自然文からの起動を止めている。`verify-skills.sh` の check 9 が一致を検査する
- **hook の信頼**: Codex は hook の信頼を「配列上の位置と定義」に紐づけ、変わった hook は `/hooks` で信頼し直すまでスキップする（= ガードが黙って開く）。install は自前の hook だけを各イベントの先頭に置いて、Orca・Muxy の位置を動かさない。`./setup.sh install` が hooks.json を書き換えたら（install が最後に案内する。信頼は定義に紐づき、スクリプトの中身には紐づかないので、スクリプトの更新だけでは外れない）、Codex で `/hooks` を開いて「要レビュー」が出ていないか確認する（check 12 が位置と信頼キーを検査する）。install の hooks.json の段が「先頭の自前グループの後ろに自前の hook があります」で失敗したら（hooks.json には書き込まない）、自前の hook を先頭のグループにまとめてから install をやり直し、`/hooks` でそのイベントの全件を信頼し直す
- Codex は `ask`（確認プロンプト）に未対応なので、確認が要る操作の hook は Codex では `deny` で止め、理由に `[要確認]` と付ける。モデルはユーザーに確認して、ユーザー自身に実行してもらう（SKILL.md の lint の frontmatter の deny は、直した内容で再実行する）
- **Codex の Claude からの取り込み**（`/import` と、起動時の案内）は、ユーザーが進めたときだけ動く。移すのは `~/.claude/CLAUDE.md`・repo の `CLAUDE.md`・hook・skills・subagent・設定・MCP・最近の会話で、**既にある `AGENTS.md`・`hooks.json`・skills・subagent は上書きしない**（移し先が無いか空のときだけ書く。0.160.0・0.162.0 のソースと、2026-10-09 の実機で確認）。書くときは「Claude → Codex」の語の機械的な置き換えがかかるので、パス（`~/.claude/scripts/` 等）が壊れる。次の 2 つに注意する
  - `~/.codex/AGENTS.md` や `hooks.json` を消した・空にした後に取り込むと、置き換えの入った版が書き戻される。取り込みの前に `./setup.sh install` を済ませておく（install がブロックと自前 hook を入れるので、移し先が空でなくなる）
  - `shared/agents/` に足した agent を install する前に取り込むと、生成ヘッダの無い TOML ができ、install が手書きと見なして上書きしない（古いまま残る）。足したら先に `./setup.sh install` する
- `~/.agents/skills` は他のツール（skills CLI 等）も書き込む共有の場所。同名の実体（例: Bugbot 用の `review`）があると install は触らず warn する。その名前を Codex で呼ぶと、repo の skill ではなく既存の実体が起動する（例: `$review` は Bugbot のレビューを走らせ、`tmp/review/unified.md` を作らないので `/fix` へ続かない）。repo 側を使うなら、既存の実体を別名に退避してから install し直す
- Codex が読む指示は `~/.codex/AGENTS.md` と repo 直下の `AGENTS.md` の合計で 32 KiB まで。超えると後から読まれる repo 直下の `AGENTS.md` が欠ける（check 11 が検査する）
- **ガードが効かない経路**（hook では塞げないので、書き方で避ける。避け方は読み替え表にある）
  - `write_stdin` で対話シェルに打ち込んだコマンドは、どの hook も通らない
  - シェルで `apply_patch <<'EOF'` を実行すると、hook には `Bash` として届き、SKILL.md の lint に当たらない
  - `exec_command` の `workdir` は hook に渡らず、contract-link は turn の作業ディレクトリのリポジトリを検査する。tmp-commit と破壊的 git はコマンド文字列だけで判定するので影響しない。第一ガードの `skip-worktree` は経路を問わず効くので、これは 2 枚目の穴（`workdir` が渡らないことはバイナリの解析による推定で、実機の入力では採取していない）

## 📚 Skills 一覧

開発ワークフロー系（旧 commands から移行）と、ユーティリティ系（既存）に分類:

> **起動方法（重要）**: `disable-model-invocation: true` を付けた skill は **`/` 呼び出しのみ**で、自然言語からは起動しない。無反応で終わるのではなく有効な別実装（plugin など）に流れることがあるため、明示的に `/名前` で呼ぶ。
> `settings.json` の `skillOverrides: "name-only"` を付けた skill は listing に name だけ載る（description が落ちるだけで、自然言語からの起動は可能）。
> 現在の状態: `grep -l '^disable-model-invocation: true' shared/skills/*/SKILL.md | xargs -n1 dirname | xargs -n1 basename` と `jq .skillOverrides claude/settings.json`

### 開発ワークフロー系
| スキル名 | 説明 |
|---------|------|
| `/brief` | 用途別テンプレート（concept / implement / refactor / bug）で質問ファイル tmp/context.md を作成（任意の前工程） |
| `/ask` | コードベースや技術的質問への調査回答 |
| `/grill` | 計画・設計の壁打ち。業務シナリオ（主語・入口・出口）の確立から始め、決定を `tmp/grill.md`・`tmp/scenario.md` に蓄積する |
| `/html-view` | Markdown の成果物（plan・review・research 等）をローカル完結の HTML にしてブラウザで開く。完了報告での HTML 化の標準の手段（共有ページの Artifact は、共有を求められたときだけ使う） |
| `/design` | 要件・コンテキストから実装計画 (plan.md) を生成 |
| `/review-plan` | plan.md のスタッフエンジニアレビュー |
| `/revise` | フィードバックに基づき計画ファイルを修正 |
| `/implement` | 計画に基づき TDD で実装（テストの価値は基盤 skill `test-audit` と判定役 `test-auditor` で監査する） |
| `/review` | PR レビュー（並列サブエージェント） |
| `/fix` | 修正項目から fix-plan.md を生成 |
| `/create-pr` | 既定ブランチ向けドラフト PR を作成（ベースは `gh repo view` から取得） |
| `/spec-check` / `/spec-propose` / `/spec-archive` / `/document-spec` | OpenSpec 仕様管理 |
| `/review-comments` | PR レビューコメントの妥当性評価 + 返信 + resolve |
| `/retrospective` | 日次 PR 振り返り |
| `/adr` / `/state-machine` / `/status` | ADR 生成 / 状態遷移図追加 / ワークフロー進捗表示 |
| `/memory` / `/recall` | 記憶の保存・読み込み（実装は `agent-memory` skill に委譲） |
| `/coupling-audit` / `/coupling-plan-diff` / `/coupling-precheck` / `/coupling-gate` | 結合(Coupling)モデルによる分析4種（既存コード棚卸し / Before-After差分分析 / 設計前整理 / plan.mdゲート） |

### ユーティリティ系
| スキル名 | 説明 |
|---------|------|
| `agent-memory` | 記憶の保存・読み込みの実装本体（`user-invocable: false`） |
| `coupling-anatomy` | 結合モデル判定基準の実装本体（`user-invocable: false`） |
| `domain-name-brainstormer` | ドメイン名のブレインストーミング |
| `figma` | Figma 関連の操作 |
| `marp` | Marp スライド生成 |
| `blog` / `outline` | ブログドラフト / アウトライン生成 |
| `notion-adr` / `notion-qa-progress` | Notion 連携 |
| `playwright-cli` | ブラウザ自動操作 |
| `context-index` | claude-context にコードベースを index（個人定義の ignore で不要ディレクトリ除外、`disable-model-invocation`） |
| `worktree-cleanup` | マージ済み PR の worktree 一括削除（削除時に claude-context index を回収、孤児 collection の点検も行う） |
| `strategic-ddd` / `review-strategic-ddd` | 戦略的 DDD 設計と そのレビュー |
| `skill-authoring` | skill / subagent を書くときの規約（Claude 5 向け変換ルール T1–T8、起動制御フィールドの判断表、追加手順）。**起動制御の正本** |

## 🤖 SubAgents 一覧

すべて `shared/agents/<カテゴリ>/` にあり、`~/.claude/agents/` に配置される。code-reviewer と qa-expert は、pr-review-toolkit の `code-reviewer` / `pr-test-analyzer` と比べて plugin 版を採用し、削除した（2026-09-30）。

### Core Development
- `api-designer.md` - API 設計
- `backend-developer.md` - バックエンド開発
- `ddd-expert.md` - 戦術的 DDD（Entity / Value Object の分類・集約の設計）
- `documenter.md` - 仕様・計画とコードの同期（`/implement` Phase 5.5）
- `frontend-developer.md` - フロントエンド開発
- `fullstack-developer.md` - フルスタック開発
- `ui-designer.md` - UI デザイン

### Language Specialists
- `typescript-pro.md` - TypeScript エキスパート

### Infrastructure
- `cloud-architect.md` - クラウドアーキテクト
- `database-administrator.md` - データベース管理
- `devops-engineer.md` - DevOps エンジニア
- `devops-incident-responder.md` - DevOps インシデント対応
- `security-engineer.md` - セキュリティエンジニア
- `sql-pro.md` - SQL エキスパート
- `sre-engineer.md` - SRE エンジニア

### Quality & Security
- `accessibility-tester.md` - アクセシビリティテスト
- `ad-security-reviewer.md` - AD セキュリティレビュー
- `architect-reviewer.md` - アーキテクチャレビュー
- `chaos-engineer.md` - カオスエンジニアリング
- `compliance-auditor.md` - コンプライアンス監査
- `debugger.md` - デバッグ
- `error-detective.md` - エラー調査
- `penetration-tester.md` - ペネトレーションテスト
- `performance-engineer.md` - パフォーマンスエンジニアリング
- `powershell-security-hardening.md` - PowerShell セキュリティ強化
- `security-auditor.md` - セキュリティ監査
- `test-auditor.md` - テストの価値の読み取り専用判定役（`/implement` の主担当表・変更監査。`test-audit` を preload）
- `test-automator.md` - テスト自動化

### Business Analysis
- `bpmn-expert.md` - BPMN 2.0 と BPM の実装設計
- `process-modeler.md` - 業務プロセスの分析・モデリング

### Architecture
- `design-system-architect.md` - デザインシステム・UI 基盤
- `frontend-architect.md` - フロントエンドアーキテクチャ
- `react-architect.md` - React エコシステムのアーキテクチャ
- `senior-architect.md` - 設計フェーズの非機能要件の評価・技術選定
- `strategic-ddd-designer.md` - 戦略的 DDD（`strategic-ddd` を preload）

## 🔗 参考リンク

- [Claude Code Skills 公式ドキュメント](https://code.claude.com/docs/ja/skills)
- [Claude Code Sub-agents 公式ドキュメント](https://code.claude.com/docs/ja/sub-agents)

## 📝 新しい Skills/SubAgents の追加

### Skills の追加

1. `shared/skills/` 配下に新しいディレクトリを作成
2. `SKILL.md` ファイルを作成（必須）
3. `disable-model-invocation: true` を付けたら、同じ skill に `agents/openai.yaml` も置く（`policy:` の下に `allow_implicit_invocation: false`。Codex の自然文起動を止める。`verify-skills.sh` の check 9 が過不足を検査する）
4. `./setup.sh install` を再実行

```yaml
---
name: your-skill-name
description: Brief description of what this Skill does
---

# Your Skill Name

## Instructions
...
```

### SubAgents の追加

1. `shared/agents/<カテゴリ>/` に `.md` ファイルを作成する。frontmatter の `name` はファイル名と一致させ、`shared/agents/` 全体で一意にする（書き方の規約は `shared/skills/skill-authoring/SKILL.md` の「SubAgents の追加」）
2. `./setup.sh install` を再実行（`~/.claude/agents/` を初めて作った場合は、Claude Code のセッションを開き直す）。Codex には install 時に TOML が生成される（**`.md` を編集したら再実行しないと、Codex には古い TOML が残る**。`verify-skills.sh` の check 10 が検知する）

Codex では frontmatter のうち `name`・`description`・`tools`・`skills` だけが意味を持つ。`tools` に `Write`・`Edit`・`MultiEdit`・`NotebookEdit` が無い agent は `sandbox_mode = "read-only"` になり、`tools` が無い agent は親を継承する。それ以外の `tools` の制限（例: WebSearch の有無）と `model:` は Codex に渡らない。`skills:` は本文の先頭で SKILL.md を読ませる指示に変換される。未知の frontmatter キー・name とファイル名の不一致・Codex の組み込み agent（`default`・`worker`・`explorer`）と同じ name・空の本文・`tools: null` のような null・真偽値の `tools`・引用符付きや空のリスト項目は、生成がエラーになる（Codex に渡さないキーを増やすなら、`codex/gen-agents.py` の `ALLOWED_KEYS` に足す。TOML には出ない）

## ⚠️ 注意事項

- Skills / Agents / settings.json はシンボリックリンクのため、リポジトリ内のファイルを更新すると自動的に反映されます
- **Scripts は実体コピーのため即時反映されません。** `shared/scripts/` を編集・pull したら `./setup.sh install` を再実行してください。忘れても hook は失敗せず古いスクリプトで静かに動き続けます（同期状態は `./setup.sh status` か `verify-skills.sh` で確認）
- **Codex 側の agents（TOML）も生成物のため即時反映されません。** `shared/agents/` を編集したら `./setup.sh install` を再実行してください
- リポジトリを削除すると、リンクが壊れます（アンインストールを先に実行してください）
- `~/.claude/` 側の既存の実ファイル・実ディレクトリ（skills・agents、前回 install 後に手で改変された scripts）は `.backup.YYYYMMDDHHMMSS.<PID>` として退避してから置き換わります（`settings.json` は `.pre-install.*`）。Codex 側（`~/.agents/skills` の同名の他者の実体・リンク、`~/.codex/agents` の手書きの TOML）は、退避も上書きもせず warn して配置をスキップします
- **install はメインチェックアウトから実行してください。** worktree から実行すると symlink がその worktree を指し、削除時に設定が失われます（`./setup.sh install` が警告します）
