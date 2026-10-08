## Codex での読み替え表

この表は Codex でだけ読み込まれる。skill・agent の本文と「Skills 共通規約」は Claude Code の語彙で書かれているので、次の読み替えをしてから従う。表に無い語は、意味の近い Codex の機能に自分で置き換える。置き換えられないときは、**黙って省略せず**ユーザーに報告する。

### 起動と連鎖

| Claude の語 | Codex での読み替え |
|---|---|
| `/name`（skill の呼び出し） | `$name`。「`/name` 呼び出しで使用」は `$name` の明示呼び出しを指す |
| `$ARGUMENTS` | skill 名の後にユーザーが書いた文字列。無ければ「引数なし」として skill の既定に従う |
| `Skill` ツールで X を起動する | `~/.agents/skills/X/SKILL.md` を読み、その手順に従う。ファイルが無ければ止めて報告する |
| `Agent(subagent_type: X)`・「X subagent に委譲」 | custom agent `X` を spawn する。`~/.codex/agents/X.toml` が無ければ汎用 agent で代えず、停止して報告する（読み取り専用の判定役を、書き込める agent で代えると判定と修正が混ざるため） |
| 役割だけを渡す subagent（`/review` の各レビュアー等）・`run_in_background` | 役割の文面を渡して汎用 agent を spawn する。独立した役割は並列に起動し、全員の完了を待つ |

### ユーザーへの質問と進捗

| Claude の語 | Codex での読み替え |
|---|---|
| `AskUserQuestion` | 選択式の質問ツールがあれば使う。無ければ、推奨案を先頭にした番号付きの選択肢を文章で示して回答を待つ（質問の粒度・選択肢の数は skill の指定のまま） |
| `TodoWrite` | `update_plan` |

### ファイル・ツール・規約

| Claude の語 | Codex での読み替え |
|---|---|
| `Read` / `Grep` / `Glob` / `Edit` / `Write` | シェルでの読み取り・検索と `apply_patch` |
| `user-Notion:<tool>` などの MCP ツール名、「Serena MCP」「Context7 MCP」 | 同じ役割の MCP ツールが設定されていればそれを使う。無ければ skill に書かれたフォールバック（grep・Read 等）に従う |
| `CLAUDE.md` | `AGENTS.md`（グローバルは `~/.codex/AGENTS.md`） |
| `~/.claude/skills/<x>` | `~/.agents/skills/<x>`（`~/.claude/scripts/` と `~/.claude/logs/` は両ツール共通なのでそのまま） |
| Artifact（claude.ai の共有ページ）・artifact-design・dataviz | Codex には無い。読む形にするのは html-view（ローカル HTML）で足りる。共有ページを求められたら作れないと報告し、html-view の HTML を渡す案を示す |

### 記憶

| Claude の語 | Codex での読み替え |
|---|---|
| auto-memory・`~/.claude/projects/<slug>/memory/` | `~/.local/share/codex/memories/projects/<slug>/`（`<slug>` の導出規則は同じ。索引は同じディレクトリの `MEMORY.md`） |
| `~/.local/share/claude/memories/`（`/memory`・`/recall`） | `~/.local/share/codex/memories/`。`~/.codex/memories/`（Codex Memories）には書かない |

### ガードレール（hook）

| 状況 | Codex での扱い |
|---|---|
| hook の理由に「[要確認]」とあって操作が止められた | 理由の末尾の次の行動に従う。既定はユーザーに確認し、ユーザー自身に実行してもらう（理由を言い換えて同じ操作を再実行しない）。SKILL.md の lint が frontmatter の欠落で止めたときは、直した内容でなら再実行してよい |
| git 操作（add・commit・reset・push 等） | exec_command で 1 回ずつ実行する。write_stdin（対話シェルへの入力）はどの hook も通らない |
| SKILL.md の編集 | apply_patch ツールで行う。シェルの `apply_patch <<'EOF'` や exec_command での書き換えは Bash として届き、lint を通らない |
| 作業ディレクトリ以外のリポジトリでの git commit | workdir を使わず、`git -C <repo> commit …` か、wrapper で包まない `cd <repo> && git commit …` と 1 本のコマンドに書く。workdir は hook に渡らず、`bash -lc "cd … && git commit"` は contract-link の基点の解決に当たらない |
