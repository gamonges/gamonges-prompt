# Claude Skills & SubAgents Collection

Claude Code と Codex で使用するための Skills と SubAgents のコレクションです。

## 概要

このリポジトリには、すべてのプロジェクトで共通して使用できる Claude の拡張機能が含まれています。個人の Neovim の設定（`nvim/`）も管理しています。

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
│   ├── knowledge.py     # tmp/ の md の frontmatter の検査・目録（tmp/index.md）・版の保存（snapshot）
│   ├── review-to-atlas-notes.py  # /review の tmp/review/unified.md の指摘を atlas.nvim の Notes にする（手動で呼ぶ）
│   ├── statusline.py
│   ├── sync-cursor-skills.sh
│   └── verify-skills.sh
└── global-rules.md      # 全プロジェクト共通の規約（~/.claude/CLAUDE.md と ~/.codex/AGENTS.md にマーカーブロックで配置）

claude/                  # Claude Code 固有
└── settings.json        # hook 定義・deny リスト等（~/.claude/settings.json へ symlink）

nvim/                    # Neovim の設定（~/.config/nvim へ symlink。Claude と Codex の共通の段で扱う）

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
| Neovim の設定 | `~/.config/nvim`（`nvim/` への symlink。既存の実ディレクトリ・実ファイル・他所へのリンクは `nvim.pre-install.*` に退避） | （共通。Codex の段では張らない。Codex の外部エディタも nvim） |
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
bash shared/scripts/tests/test-series-sync.sh    # series-sync の同期スクリプトの挙動（偽の gh。python3 と /usr/bin/python3）。series_sync.py を編集したら
bash shared/scripts/tests/test-codex-run.sh      # codex-run.sh の挙動（偽の companion）。codex-run.sh を編集したら
bash shared/scripts/tests/test-knowledge.sh      # knowledge.py の規則・目録・snapshot と、skill の雛形の frontmatter（python3 と /usr/bin/python3）。knowledge.py か tmp/ に md を書く skill の雛形を編集したら
bash shared/scripts/tests/test-series-inbox.sh   # series-run の横断の受信箱の挙動（SERIES_RUN_STATE_DIR。python3 と /usr/bin/python3）。series_inbox.py を編集したら
bash shared/scripts/tests/test-review-to-atlas-notes.sh  # review-to-atlas-notes.py の挙動（偽の gh・偽の atlas-notes。python3 と /usr/bin/python3）。スクリプトを編集したら
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
- Codex は `ask`（確認プロンプト）に未対応なので、確認が要る操作の hook は Codex では `deny` で止め、理由に `[要確認]` と付ける。モデルはユーザーに確認して、ユーザー自身に実行してもらう（SKILL.md の lint と tmp/ の md の検査の frontmatter の deny は、直した内容で再実行する。違反の deny には `[要確認]` が付かない。`[要確認]` が付くのは CLI の失敗などの ask で、これはユーザーに確認して実行してもらう）
- **Codex の Claude からの取り込み**（`/import` と、起動時の案内）は、ユーザーが進めたときだけ動く。移すのは `~/.claude/CLAUDE.md`・repo の `CLAUDE.md`・hook・skills・subagent・設定・MCP・最近の会話で、**既にある `AGENTS.md`・`hooks.json`・skills・subagent は上書きしない**（移し先が無いか空のときだけ書く。0.160.0・0.162.0 のソースと、2026-10-09 の実機で確認）。書くときは「Claude → Codex」の語の機械的な置き換えがかかるので、パス（`~/.claude/scripts/` 等）が壊れる。次の 2 つに注意する
  - `~/.codex/AGENTS.md` や `hooks.json` を消した・空にした後に取り込むと、置き換えの入った版が書き戻される。取り込みの前に `./setup.sh install` を済ませておく（install がブロックと自前 hook を入れるので、移し先が空でなくなる）
  - `shared/agents/` に足した agent を install する前に取り込むと、生成ヘッダの無い TOML ができ、install が手書きと見なして上書きしない（古いまま残る）。足したら先に `./setup.sh install` する
- `~/.agents/skills` は他のツール（skills CLI 等）も書き込む共有の場所。同名の実体（例: Bugbot 用の `review`）があると install は触らず warn する。その名前を Codex で呼ぶと、repo の skill ではなく既存の実体が起動する（例: `$review` は Bugbot のレビューを走らせ、`tmp/review/unified.md` を作らないので `/fix` へ続かない）。repo 側を使うなら、既存の実体を別名に退避してから install し直す
- Codex が読む指示は `~/.codex/AGENTS.md` と repo 直下の `AGENTS.md` の合計で 32 KiB まで。超えると後から読まれる repo 直下の `AGENTS.md` が欠ける（check 11 が検査する）
- **ガードが効かない経路**（hook では塞げないので、書き方で避ける。避け方は読み替え表にある）
  - `write_stdin` で対話シェルに打ち込んだコマンドは、どの hook も通らない
  - シェルで `apply_patch <<'EOF'` を実行すると、hook には `Bash` として届き、SKILL.md の lint と tmp/ の md の検査に当たらない
  - `exec_command` の `workdir` は hook に渡らず、contract-link は turn の作業ディレクトリのリポジトリを検査する。tmp-commit と破壊的 git はコマンド文字列だけで判定するので影響しない。第一ガードの `skip-worktree` は経路を問わず効くので、これは 2 枚目の穴（`workdir` が渡らないことはバイナリの解析による推定で、実機の入力では採取していない）

### tmp/ の md の frontmatter 検査

`tmp/` の md には OKF v0.2 の frontmatter（`type`・`title`・`description`・`status`）が要る。書式は `python3 ~/.claude/scripts/knowledge.py spec`、種類の一覧は `knowledge.py types`。今ある文書の一覧は `knowledge.py lint`（違反があれば exit 1）、目録 `tmp/index.md` は `knowledge.py index` で作り直す。上書きが契約の成果物の旧版は `knowledge.py snapshot <path>… --reason <理由>` で `<名前>.archived-<YYYYMMDD-HHmm>-<理由><拡張子>` に残す（元の中身と mtime は変えない。名前の理由は語の文字・`.`・`-` 以外を `-` にしたもので、元の文は写しの `archived_reason` に残る）。

判断記録（AGENTS.md に置かないのは、Codex の指示のサイズの上限のため）:

- **既存の hook（`hook-lint-skill-frontmatter.sh`）に対象を足した。** apply_patch の解釈はこの hook にしか無く、新しい hook を足すと settings.json が変わって Codex の信頼し直しが要る。判定の本体（必須キー・対象の判定・違反の比較・雛形）は `knowledge.py check` だけが持ち、hook は書いた後と書く前の中身を作って渡すだけ
- **対象**: `.git` のあるディレクトリ直下の `tmp/` の `.md`。`tmp/_runs/`（生ログ）・`tmp/_assets/`（画像）の下と、`index.md`・`log.md`・`SKILL.md` は外す。scratchpad（`/private/tmp/…`）は `tmp` の親に `.git` が無いので外れる。名前の大文字小文字は区別しない（`TMP/`・`.MD`。APFS に合わせる）。パスの字面で当たらなければ symlink を解決した実体でも見る（字面が先なので、repo の外へ向けた `tmp/` の symlink も対象。実体はまだ無い末尾を残して解決する）
- **今ある文書は必須にしない（grandfather）。** 書く前の中身に frontmatter が無い Edit・Update File は必須の 4 キーの不足を問わない。frontmatter を持つ文書の編集は、違反の種類（`missing:<key>`・`invalid:<key>`・`no-frontmatter`・`unsupported-syntax`）の集合が増えないものだけを通す。install 前の不完全な frontmatter（brief の context.md・`status` の無い grill.md）への Edit・Update File での追記はこれで通る（Write で全体を書き直すと、書く前の中身を問わず 4 キーが要る）。比べるのは違反の種類で、値の変化（`status: foo` → `bar`）は見ない。frontmatter の無い文書に frontmatter を付ける Edit・Update File は、必須の 4 キーの不足だけを免除し、付けた値の誤り（`invalid:status`、`deprecated` での `superseded_by` の欠落等）は止める（誤った値が以後の Edit の基準にならないように）。Write と Add File、無いファイルを作る Edit・MultiEdit（空の `old_string`）は書く前の中身を問わず必須。対象外の場所から `*** Move to:` で tmp/ に入る文書も免除しない
- **fail-closed の範囲**: CLI が無い・exit 2・python が無いときは、tmp/ の md の書き込みだけを ask（Codex は `[要確認]` の deny）にする。「tmp/ の md か」は bash 側でも判定する（`.git` の確認だけ。除外は CLI に任せ、CLI が無ければ除外に当たるものも止める＝安全側）ので、scratchpad の md は CLI が無くても止まらない。apply_patch を解釈できないときは、見出し（Add File・Update File・Move to）のパスを cwd で解決して tmp/ の md に触れる疑いを見る（文字列の部分一致にすると、cwd が tmp/ の下の相対パスを見落とし、scratchpad を誤って止める）
- **Bash で書かれた md は通る**（`cat >`・`tee`・python）。既存の deny と同じく Read/Edit/Write/apply_patch の経路だけを守る。漏れは `knowledge.py lint` で拾う
- **YAML との互換**: check は YAML の部分集合として寛容に読み、YAML パーサとの互換は保証しない（`title: 調査: 既存の hook` も通す）。knowledge.py が書く値（snapshot の写し）は、要るときだけ単一引用にして YAML としても読める形にする。保存庫・ナレッジ化で YAML パーサを使うときに check を厳しくする
- **プロジェクト単位では外せない**: hook はグローバルに効き、外部の書き手（`/goal` の `tmp/goal.md`・グローバル CLAUDE.md の `tmp/plan.md`）も初回は deny を挟む。理由に雛形が出て 1 回で回復できる。外す手段を足すと、外したまま忘れても気づけない（ガードが黙って開くのと同じ型）ので足さない
- **AGENTS.md の挙動テストの一覧に `test-knowledge.sh`・`test-series-inbox.sh`・`test-review-to-atlas-notes.sh` は足していない**: Codex の指示（`~/.codex/AGENTS.md` ＋ repo の AGENTS.md）は既に上限 32 KiB を超えている（F-5）。一覧は上の「挙動テスト」と `verify-skills.sh --with-behavior-tests` が持つ。F-5 の解消時に AGENTS.md へ移すかを決める
- **止まったら**: deny の理由に付けるべき frontmatter の雛形が出るので、それを先頭に足して書き直す。ask（CLI の失敗）は `./setup.sh install` 済みか（`~/.claude/scripts/knowledge.py` があるか）を確かめる

### git push の確認と .env 系の制限

判断記録（AGENTS.md に置かないのは、上と同じく Codex の指示のサイズの上限のため。settings.json はコメントを書けない）:

- **`permissions.ask` の `Bash(git push:*)` を外し、既定のブランチへの push だけを `hook-confirm-destructive-git.sh` で ask にした。** worker の feature ブランチへの push は毎回 Yes で、毎回の確認は中身を読まずに承認する習慣を育てる（ガードを別の方向から無効にする）。既定のブランチは `main`・`master`・`develop` と `refs/remotes/<リモート>/HEAD` の値（取れなければ名前の 3 つだけ）。Codex では `[要確認]` の deny。`release/*`・`trunk`・`production` などは集合に入れず、GitHub の branch protection に任せる（`refs/remotes/<リモート>/HEAD` が指すときだけ既定のブランチとして扱う）
- **押す先は引数と git の参照から求め、求められなければ ask に倒す。** `<src>:<dst>` は dst、`<name>` は同名、`HEAD`・`@` は `symbolic-ref HEAD`、refspec が無ければ `@{push}`。`--all`・`--branches`・`--mirror`・`--prune`・`--repo`、知らないオプション、git のグローバルオプション（`-C` と押す先に関わらないもの以外。`-c`・`--git-dir` など）、`$`・バッククォート・glob を含む引数、`sudo`・`xargs`・`ssh` などのラッパーの中、許可に無い `GIT_*` の代入・`export`（`GIT_CONFIG_*`・`GIT_DIR` は hook から見えない所で押す先を替える。`GIT_TRACE*`・`GIT_SSH_COMMAND` などは通す）、`push.default=matching` の refspec の無い push（`git push`・`git push origin`。同名の全ブランチを押す）、明示したリモートと `@{push}` のリモートの食い違い、`remote.<r>.push` の設定（`@{push}` は今のブランチの対応しか返さないが、`git push <r>` は設定の全部を押す。`:<dst>` を省いた明示の refspec も、この設定が押す先を替える）は ask。refspec の `+`（強制）も宛先によらず ask（force の判定は `-f`・`--force`・`--force-with-lease` しか拾わず、permissions.ask を外すと `+` を止める経路が無くなるため）
- **`git push --dry-run` は使わない。** pre-push のフック（テスト・ネットワーク）を走らせる
- **コマンドの書き方によらず push を見つける。** 前段は引用符・バックスラッシュ・改行を除いて `push` を含むかだけを見て、判定を python に任せる（前段を正規表現で絞ると、`"git" push`・`g\it push`・行の継続・`-C.` が python に届かず素通しになった）。python は、予約語とグループの記号（`if`・`then`・`do`・`{`・`!`・`time` など）を前置きとして読み飛ばし、コマンド置換（`$(…)`・バッククォート。二重引用の中も）の中を同じ判定で読み、`bash -c`・`sh -c`・`eval` の中身も同じ判定で読む（既定でないブランチへの push は通す）。ヒアドキュメントの本文は実行されないので、引用・算術式の外の `<<` から本文を除いてから読む（除かないと、commit メッセージの本文の行を push と読む）。引用無しのヒアドキュメント（`<<EOF`）の本文の中のコマンド置換は実行されるので、同じ判定で読む。行の継続はシェルの意味どおり語をつなぐ
- **安全側の誤検出**: 別々の語の `git` と `push` を含む未知のコマンド（`echo git push origin main`）は ask になる。単一引用の中のコマンド置換（`echo '… $(git push origin main) …'`）はシェルが実行しないので読まずに通す（`bash -c '…'`・`eval '…'` の中身は上のとおり読み、`ssh host '…'` などのラッパーは中に `git push` があれば ask）
- **残差**（判定できないので通る）: git の alias（`git p origin main`）、セッションで前に export した `GIT_*` や変数（`git $P` の P を前のコマンドで決めたもの）、Monitor・Serena の `execute_shell_command` 経由の push（Bash の matcher に当たらない。変更前から同じ）、`cd` の後と Codex での `remote.<r>.push`・`refs/remotes/<r>/HEAD`（入力の cwd でしか確かめない。cwd で見つかったときだけ ask を足す）
- **マージから install までの時差**: settings.json は symlink なので pull の時点で効き、scripts は `./setup.sh install` まで古い。その間は既定のブランチへの push に確認が出ず、`hook-guard-env-files.sh` も無いので exit 127（non-blocking）になり `.env.local` 等も守られない。pull と install を 1 つの手順で行う。Orca のプロファイルの settings.json（通常のファイル）を追従させるのは install の後
- **判定のディレクトリが取れない入力は ask に倒れる。** `cd x && git push` の移動先と、Codex の `exec_command` の `workdir` は hook に渡らない。`-C` が無く、押す先を求めるのに git の参照が要る（refspec が無い・`HEAD`・`@`）ときは ask（Codex では deny）。ブランチ名を明示した refspec と、`git -C <dir> push …` は判定できるので通る（series-run の push は `-C` 付き）
- **.env 系の判定を `hook-guard-env-files.sh`（Read・Edit・Write・MultiEdit・Grep・NotebookEdit・apply_patch）に移した。** permissions は否定を書けず、deny が allow より先に評価されるので、`**/*.env*` の deny のままでは `.env.example`・`.env.sample` の allow が効かない（効いていない allow は外した）。判定は basename を小文字にして、`.env` と一致・`.env.`・`.env-`・`.env_` で始まる・`.env` で終わる・`<名前>.env.<拡張子>`（`prod.env.bak`・`secrets.env.json`）を deny。通すのは、区切りが `.`・`-`・`_` の example・sample と `<名前>.env.example`・`<名前>.env.sample`（見本）、`<名前>.env.<コードの拡張子>`（`x.env.ts` など。basename が `.env` で始まる `.env.ts` は止める）。`env/stg.ts`・`app-env.ts`・`.envrc` は通る。symlink は解決した先の名前でも判定する（相対パスは入力の cwd が基点）
- **`.envrc` は通す**: direnv の設定でシェルのコードを含み、読めないと direnv の設定を扱えない。秘密を置く運用なら、permissions の deny に `Read(**/.envrc)` を足す
- **Grep で覆う範囲**: `path` がファイルのときと、`glob` が `.env` 系を指すとき（`*.env*`・`**/.env.local`。`**/*.env.ts` は通す）だけ。ディレクトリを対象にした glob 無しの Grep は覆わない
- **Codex での範囲**: Codex はシェルで読むので、守られるのは apply_patch の書き込みだけ。hooks.json の信頼をし直すまでは、Codex では本 hook 自体もスキップされる
- **例外の無い名前は permissions にも残す**（`Read/Edit(**/.env)`・`Read/Edit(**/*.env)`）。hook が install 漏れなどで動かないときにも、最も多い `.env` は止まる
- **apply_patch は見出しで判定する**: Add File・Update File・Delete File と、Move to の移動先（移動元は Update File の見出し）。見出しが読めない patch は、本文に `.env` を含むときだけ止める（全部止めると、文法が将来変わったときに Codex の編集が全部止まる）
- **出すのは deny だけ**（ask を出さない）。秘密を読む操作に「承認すれば通る」経路を作らない。理由には「必要ならユーザーに依頼する」と書く。check 7(1) の ask を返す hook の一覧には入らない
- **Bash 経路（`cat .env`）は塞がない**（AGENTS.md の deny の判断記録の方針のまま）
- **この変更のきっかけの「`env/stg.ts` の編集が止められた」は、`.claude/worktrees/<名前>/env/…`（worktree の下）での出来事だった。** 当時の deny（`**/*.env*`）はこの名前に一致しないので、Claude Code の `.claude/` の下の保護で止まった可能性が高い（未確定。確かめていない）。本 hook はこの名前を通すが、`.claude/` の保護は別の仕組みで、本 hook では変わらない
- **入れたら**: Codex では PreToolUse の自前グループが 1 つ増えるので、`./setup.sh install` の後に `/hooks` で PreToolUse の全件を信頼し直す

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
| `/series-init` / `/series-sync` | 複数の PR に分けた対応の全体像。横断計画からシリーズの契約と引き継ぎを作り、各 PR の本文の全体像を同期する |
| `/series-run` | シリーズの監督。series-init の手順の後、各 worktree に工程別の worker（design → implement → review → fix → recheck）を起動し、質問と完了報告を 1 つのセッションに集める（Orca の orchestration を使う。`/` 呼び出しのみ） |
| `/spec-check` / `/spec-propose` / `/spec-archive` / `/document-spec` | OpenSpec 仕様管理 |
| `/review-comments` | PR レビューコメントの妥当性評価 + 返信 + resolve |
| `/retrospective` | 日次 PR 振り返り |
| `/adr` / `/state-machine` / `/status` | ADR 生成 / 状態遷移図追加 / ワークフロー進捗表示 |
| `/memory` / `/recall` | 記憶の保存・読み込み（実装は `agent-memory` skill に委譲） |
| `/coupling-audit` / `/coupling-plan-diff` / `/coupling-precheck` / `/coupling-gate` | 結合(Coupling)モデルによる分析4種（既存コード棚卸し / Before-After差分分析 / 設計前整理 / plan.mdゲート） |

`/review` と `/review-plan` は、Codex plugin（`codex@openai-codex`。`claude/settings.json` で有効化）で Codex のレビュアーを 1 本足す（`/plan-lgtm` の中では初回だけ）。plugin が無い・未ログインなどで使えなければ、レポートに「未実施（理由）」と書いて続行する。

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

- Skills / Agents / settings.json / nvim はシンボリックリンクのため、リポジトリ内のファイルを更新すると自動的に反映されます
- **Scripts は実体コピーのため即時反映されません。** `shared/scripts/` を編集・pull したら `./setup.sh install` を再実行してください。忘れても hook は失敗せず古いスクリプトで静かに動き続けます（同期状態は `./setup.sh status` か `verify-skills.sh` で確認）
- **Codex 側の agents（TOML）も生成物のため即時反映されません。** `shared/agents/` を編集したら `./setup.sh install` を再実行してください
- リポジトリを削除すると、リンクが壊れます（アンインストールを先に実行してください）
- `~/.claude/` 側の既存の実ファイル・実ディレクトリ（skills・agents、前回 install 後に手で改変された scripts）は `.backup.YYYYMMDDHHMMSS.<PID>` として退避してから置き換わります（`settings.json` と `~/.config/nvim` は `.pre-install.*`）。Codex 側（`~/.agents/skills` の同名の他者の実体・リンク、`~/.codex/agents` の手書きの TOML）は、退避も上書きもせず warn して配置をスキップします
- **install はメインチェックアウトから実行してください。** worktree から実行すると symlink がその worktree を指し、削除時に設定が失われます（`./setup.sh install` が警告します）
