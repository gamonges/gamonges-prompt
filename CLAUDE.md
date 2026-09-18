# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

Claude Code で使用する Skills、SubAgents のコレクション。すべてのプロジェクトで共通利用するための拡張機能を管理するリポジトリ。コードの実装はなく、プロンプト（Markdown）の管理が主目的。


## セットアップ

```bash
./setup.sh install                  # Scripts は実体コピー、Skills・SubAgents・settings.json は symlink
./setup.sh install --prune-scripts  # 上記に加え、repo に無い ~/.claude/scripts/ の orphan を退避して削除
./setup.sh status                   # インストール状態の確認
./setup.sh uninstall                # インストールしたものを撤去
./setup.sh migrate                  # 旧形式 (commands→skill 化されたディレクトリ) を撤去して新形式へ移行
```

**他端末への展開時の手順**: `git pull && ./setup.sh migrate && ./setup.sh install`

配置方式は 2 通り:

- **skills / subagents / settings.json**: symlink。repo の更新が即座に反映される
- **scripts**: 実体コピー。**`claude/scripts/` を編集・pull したら `./setup.sh install` を再実行する。** 忘れても hook は「失敗」せず**古いスクリプトで静かに動き続ける**。symlink をやめたのは、メインチェックアウトがスクリプトを含まないブランチにある間に解決できず全 hook が exit 127 になるため。exit 127 は non-blocking なのでガードレールは「止まる」のではなく**開く**

**install はメインチェックアウトから実行する。** settings.json と skills は symlink のままなので install 元のチェックアウトを全プロジェクトのランタイムが参照する。worktree から install すると、その worktree を削除した瞬間に deny リスト・hook 定義・全 skill がまとめて失われる（hook と違って何も失敗しないので気づけない）。linked worktree から実行すると `./setup.sh install` が警告する。

構造的検証は `./claude/scripts/verify-skills.sh`（fail があれば exit 1、warn のみなら exit 0。check 4 が scripts の同期・orphan・install 元を、check 5 が listing budget を見る）。

**ガードレールの挙動検証は `bash claude/scripts/tests/test-guardrails.sh`（`claude/scripts/` を編集したら実行する）。** 対象はいずれも fail-open 型（ガードが黙って開く / error が黙って消える）で、壊れても何も起きないため通常の動作確認では検知できない。CI が無い本リポジトリでは、このテストが回帰を捉える唯一の手段になる。`./claude/scripts/verify-skills.sh --with-behavior-tests` からも呼べる。

### settings.json のリポジトリ管理

`~/.claude/settings.json` は repo 内 `claude/settings.json` への symlink として管理する。Git 履歴で変更追跡 + `git restore` でロールバック可能。`./setup.sh install` が冪等に symlink を再構築する。

### env-var indirection パターン（機微情報の正規取り扱い）

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

### deny リストの判断記録（settings.json はコメントを書けないためここに置く）

`"defaultMode": "bypassPermissions"` かつ `"skipDangerousModePermissionPrompt": true` のため、allow / ask は実質機能せず **`deny` がほぼ唯一の実効ガード**。deny からパターンを外すときは理由をここに残す。

- **AWS 資格情報**: `Read/Edit(**/.aws/**)` と `Read/Edit(**/*credentials*)` で保護する。`*aws*` の全面 deny は `aws-cdk-lib` / `aws-sdk` 等の通常のソースファイルに誤爆するため採らない。`~/` 表記は permission パターンで展開されるかを実測していないため、パス基準の `**/.aws/**` を使う
- **誤爆したとき**: `bypassPermissions` 下では deny にマッチした操作は確認プロンプトなしでブロックされる（ask へのフォールバックがない）。`~/.claude/settings.local.json` で一時的に上書きするか、`claude/settings.json` の該当パターンを外す
- **Bash 経路は塞いでいない**: `Bash(cat:*)` / `Bash(grep:*)` が allow のため `cat ~/.aws/credentials` は通る。deny は Read/Edit ツール経路の defense-in-depth であり、完全な封鎖ではない
- **deny の実効性は未確認（2026-07-27 実測）**: scratchpad 配下に `.aws/credentials` を作って Read したところ **ブロックされずに読めた**（`Read(**/.aws/**)` が deny にあるにもかかわらず発火しない）。ただし scratchpad は権限チェックが緩和されている可能性があり、repo 内での再検証は permission により実施できなかったため、**「deny が機能していない」と断定はできない**。この前提が確認できるまで、deny パターンの調整（`**/*credentials*` が `credentials.ts` 等に誤爆する / `aws-exports.js` が保護外になる、という指摘）は**保留する** — 発火しないパターンを変えても保護は増えず、誤爆リスクだけが増えるため。実効性の確認が先

### hook 登録の判断記録（settings.json にコメントを書けないため）

`hook-block-local-contract-link.sh`（PreToolUse / Bash）: 依存宣言が `link:` / `file:` のままの `package.json` を staged にした `git commit` を `ask` にする。

- **パッケージ名もリポジトリパスも持たない汎用パターン**にした。settings.json は PUBLIC リポジトリにコミットされるため引数にパスを書けず、Claude Code は settings.json `env` の `${VAR}` 展開を非サポートなので環境変数でも渡せない。汎用にすると適用範囲も広がる（pnpm workspace は `workspace:` を使うので、コミットされた `link:` / `file:` はほぼ常に事故）
- **`deny` ではなく `ask`**。`file:` を正規に使うリポジトリでの誤爆に備える（`bypassPermissions` 下では deny は確認プロンプトなしでブロックされる）
- **足切り（基点に `pnpm-lock.yaml` が無ければ素通し）を fail-closed より前に置く**。逆順だと変数展開を含む commit が pnpm 非使用リポジトリでも `ask` になり、**本リポジトリ自身が該当する**。日常的に出る ask は「中身を読まずに承認する習慣」を育て、fail-open とは別方向で同じくガードを無効化する
- **第一ガードは hook ではない**。`link-contract.sh` が張る `git update-index --skip-worktree` が経路を問わず巻き込みを防ぎ、hook は 2 枚目（Claude Code の Bash 経路のみ / wrapper 経由の commit は素通し）

### portability 課題（F-7 で対応予定）

`claude/settings.json` には個人固有絶対パス（mise の Node 絶対パス、`statusLine.command` の絶対パス等）が含まれる。別端末への展開は F-7 解決まで非対応。

## 主要ワークフロー（Skills）

Skills は開発ワークフローの各ステップを担う。**下図の矢印は手順の順序であり、自動で流れるパイプラインではない** — 各ステップは `/<skill-name>` で明示的に呼び出す:

### 簡易フロー（新規仕様の追加）

```
/ask → /design → /spec-check → /review-plan ⇄ /revise → /implement
  → /review → /fix → /implement fix-plan → /spec-archive → /create-pr
```

### 完全フロー（既存仕様の修正）

```
/ask → /design → /spec-check → /review-plan ⇄ /revise → /implement
  → /review → /fix → /implement fix-plan → /spec-propose → (レビュー) → /spec-archive {change-name} → /create-pr
```

主要 skill は `claude/skills/` 配下、`/<name>` で呼び出し。詳細は各 SKILL.md および `./setup.sh status` で確認できる。

### 自然言語では起動しない skill

`disable-model-invocation: true` を付けた skill は **`/` 呼び出しのみ**で、自然言語からは起動しない（一覧: `grep -l 'disable-model-invocation: true' claude/skills/*/SKILL.md | xargs -n1 dirname | xargs -n1 basename`）。

**無反応で終わるのではなく、有効な別実装に流れる**点に注意する。例: 「worktree を掃除して」は `worktree-cleanup` ではなく commit-commands plugin の `clean_gone` に吸われ、claude-context index の `clear_index` 回収が行われずに collection が孤児化する。`/worktree-cleanup` と明示すること。

## Skills 共通規約

本リポジトリの全 skill には以下の規約を適用する。**各 SKILL.md では詳細を再宣言せず、`**規約**: …` のようなマーカー行も置かない**（本ファイルは常時ロードされるため、46 skill に同じ 1 行を置くのは重複でしかない）:

- 出力は日本語（技術用語・コード例は英語のまま）
- `tmp/` 配下のファイルはコミットしない
- レビュー指摘・コード参照は `file_path:L{number}` 形式
- ソースコードを変更しない skill は、出力先を skill 本文に明記する（例: `./tmp/research.md`）
- 成果物を人が読む形にする場合、完了報告に続けて **Artifact 化を提案する（既定）**。提案は**完了報告時に 1 回だけ**行い、同一実行内で再提案しない。実行時は `artifact-design` skill に従い、`html-view` の reference は参照しない（設計指針を二重管理しないため）。ローカルに閉じたい場合のみ `/html-view <file>` を案内する
  - **例外: `grill`** — 進行中の全体感を共有することが目的のため、**Phase 0 の完了時に 1 回提案し、以後は決定が入るたびに同一 URL へ再 publish する**（提案は 1 回で、再 publish は提案ではない）

> skill / subagent を書くときのプロンプト規約（Claude 5 向けの変換ルール T1–T8、維持リスト K、起動制御フィールドの選び方、追加手順）は `claude/skills/skill-authoring/SKILL.md` に集約している。

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
