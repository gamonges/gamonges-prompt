#!/usr/bin/env bash
# ガードレールの「挙動」のリグレッションテスト。構造の検査は verify-skills.sh が担う。
#
# 対象はいずれも fail-open 型の不具合（ガードが黙って開く / error が黙って消える）で、
# 壊れても何も起きない。通常の動作確認では検知できないため、回帰を捉える手段はここしかない。
#
# 検査対象は repo 側の実体に固定する。install 済み（~/.claude/scripts/）を見ると、
# ./setup.sh install を忘れた状態で古い版を検査して PASS し、まさにこのテストが
# 守ろうとしている fail-open と同型の穴になる。
#
# 本ファイルは claude/scripts/ 直下ではなく tests/ に置く。setup.sh の install_scripts()、
# verify-skills.sh、hook-check-scripts-sync.sh はいずれも claude/scripts/*.sh を glob するため、
# サブディレクトリなら配布・同期検査・orphan 検査のすべてから外れる。実行権限も付かないので
# `bash claude/scripts/tests/test-guardrails.sh` で起動する。
#
# 依存: bash / git / jq / node（いずれも本 repo の運用で既に必須）

# set -e は使わない。1 件目の失敗で残りが走らなくなると、修正前に「4 件すべてが FAIL する」
# ことを確認できず、TDD の Red フェーズが成立しない
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

HOOK="$REPO_ROOT/claude/scripts/hook-block-local-contract-link.sh"
LINT="$REPO_ROOT/claude/skills/verify-scenario/scripts/verification-lint.mjs"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass_count=0
fail_count=0

pass() { echo -e "${GREEN}[PASS]${NC} $1"; pass_count=$((pass_count + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; fail_count=$((fail_count + 1)); }

for required in "$HOOK" "$LINT"; do
    if [[ ! -f "$required" ]]; then
        echo "test-guardrails.sh: 検査対象が見つからない: $required" >&2
        exit 2
    fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# fixture の git は利用者の設定に依存させない（署名要求やテンプレートで落ちないように）
git_init() {
    mkdir -p "$1"
    git -C "$1" init -q
    git -C "$1" config user.email test@example.com
    git -C "$1" config user.name test-guardrails
    git -C "$1" config commit.gpgsign false
}

# PreToolUse hook は stdin から JSON を受け取る
run_hook() {  # $1=command, $2=cwd
    jq -n --arg c "$1" --arg w "$2" '{tool_input:{command:$c},cwd:$w}' | bash "$HOOK" 2>&1
}

assert_contains() {  # $1=ラベル, $2=実出力, $3=期待する部分文字列
    if [[ "$2" == *"$3"* ]]; then
        pass "$1"
    else
        fail "$1"
        echo "       期待する部分文字列: $3" >&2
        echo "       実際の出力: ${2:-（出力なし）}" >&2
    fi
}

# ガードが「出ない」ことを守る検査。過剰検知（日常的に出る ask）は、読まずに承認する習慣を
# 育てて fail-open とは逆方向からガードを無効化するため、検出と同じく回帰を捉える必要がある。
# hook の trace はログファイルにしか書かないので、素通し時の出力は空になる
assert_empty() {  # $1=ラベル, $2=実出力
    if [[ -z "$2" ]]; then
        pass "$1"
    else
        fail "$1"
        echo "       出力が無いことを期待した。実際の出力: $2" >&2
    fi
}

# --- F-1: monorepo のサブディレクトリから commit してもガードが働く ---
# 足切りが $base/pnpm-lock.yaml しか見ずリポジトリルートへ遡らないと、apps/web を cwd にした
# commit が「pnpm 非使用」と誤判定されて素通しする。守る対象が apps/<app>/package.json である以上、
# その app ディレクトリでの commit は例外ではなく主経路
f1="$WORK/f1"
git_init "$f1"
mkdir -p "$f1/apps/web"
touch "$f1/pnpm-lock.yaml"
echo '{"dependencies":{"@x/contract":"1.0.0"}}' > "$f1/apps/web/package.json"
git -C "$f1" add pnpm-lock.yaml apps/web/package.json
git -C "$f1" commit -qm init
echo '{"dependencies":{"@x/contract":"link:../../../contract"}}' > "$f1/apps/web/package.json"
git -C "$f1" add apps/web/package.json
assert_contains \
    "F-1 monorepo のサブディレクトリ (apps/web) を cwd にした commit で ask になる" \
    "$(run_hook 'git commit -m x' "$f1/apps/web")" \
    '"permissionDecision": "ask"'

# --- F-2: git commit -am を検知する ---
# 判定材料が diff --cached だけだと、staged していない link: を -a で取り込む形が素通しする。
# link-contract.sh は skip-worktree の効能として commit -a を明示しており、本 hook は
# それを張り忘れた場合の 2 枚目なので、この経路を見ないと 2 枚目の意味が薄れる
f2="$WORK/f2"
git_init "$f2"
mkdir -p "$f2/apps/web"
touch "$f2/pnpm-lock.yaml"
echo '{"dependencies":{"@x/contract":"1.0.0"}}' > "$f2/apps/web/package.json"
git -C "$f2" add pnpm-lock.yaml apps/web/package.json
git -C "$f2" commit -qm init
# staged にしない。-a が拾う経路を検査する
echo '{"dependencies":{"@x/contract":"link:../../../contract"}}' > "$f2/apps/web/package.json"
assert_contains \
    "F-2 unstaged な link: を git commit -am で取り込む形で ask になる" \
    "$(run_hook 'git commit -am x' "$f2")" \
    '"permissionDecision": "ask"'

# --- F-3: draft: 判定がエントリ末尾の注記に反応しない ---
# collectDrivingEntries が継続行を連結するため、判定を連結済み文字列に当てると
# 「注: … draft: …」という注記だけで実行済み行が未実行扱いになり、actual: 欠落の error が消える
f3="$WORK/f3"
mkdir -p "$f3"
cat > "$f3/verification.md" <<'MARKDOWN'
# cap Verification

## Preconditions

## Sub-features

## How to get to it

## Driving it

- [x] 保存ボタンを押す → 一覧に反映される
      Side effect: `SELECT id FROM orders WHERE organization_id = :org;`
      → expected: 1 件
      注: 未実行の行には draft: を付けること

## Gotchas
MARKDOWN
assert_contains \
    "F-3 末尾注記の draft: で実行済み行の actual: 欠落 error が消えない" \
    "$(node "$LINT" "$f3/verification.md" 2>&1)" \
    'actual: が無い'

# --- F-4: repo ルート以外から相対パスで起動しても spec 追従チェックが働く ---
# file / specPath を cwd 相対のまま git -C <toplevel> へ渡すとパスが解決できず、
# git status が一致 0 件で素通りし git log が空を返して「履歴が無い」に化ける。
# verify-scenario/SKILL.md は「skill は対象リポジトリの外から実行される」と明記しており、
# 任意の cwd からの起動が主経路
#
# コミット時刻は決定的に与える。lint は git log --format=%ct の秒精度で比較するため、
# 2 コミットが同一秒に入ると修正が正しくても warn が出ない
f4="$WORK/f4"
git_init "$f4"
mkdir -p "$f4/openspec/specs/cap"
cat > "$f4/openspec/specs/cap/verification.md" <<'MARKDOWN'
# cap Verification

## Preconditions

## Sub-features

## How to get to it

## Driving it

- [x] 保存ボタンを押す → 一覧に反映される
      Side effect: `SELECT id FROM orders WHERE organization_id = :org;`
      → actual: 1 件 / expected: 1 件

## Gotchas
MARKDOWN
echo '# cap spec' > "$f4/openspec/specs/cap/spec.md"
git -C "$f4" add openspec/specs/cap/verification.md
GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' \
    git -C "$f4" commit -qm verification
git -C "$f4" add openspec/specs/cap/spec.md
GIT_AUTHOR_DATE='2020-01-02T00:00:00Z' GIT_COMMITTER_DATE='2020-01-02T00:00:00Z' \
    git -C "$f4" commit -qm spec
assert_contains \
    "F-4 repo ルート以外から相対パスで起動しても spec.md 追従 warn が出る" \
    "$(cd "$f4/openspec/specs" && node "$LINT" cap/verification.md 2>&1)" \
    'spec.md の最終コミットが verification.md より新しい'

# --- G-1: 正常な pnpm workspace 依存で ask にならない ---
# lockfile 側の検査が version: を見ると、workspace 依存が取る正しい姿 (version: link:...) に
# 一致して日常的に ask が出る。検出漏れではなく過剰検知の回帰を捉えるテスト
g1="$WORK/g1"
git_init "$g1"
mkdir -p "$g1/apps/web" "$g1/packages/ui"
cat > "$g1/pnpm-lock.yaml" <<'LOCK'
importers:
  apps/web:
    dependencies: {}
LOCK
echo '{"dependencies":{}}' > "$g1/apps/web/package.json"
git -C "$g1" add pnpm-lock.yaml apps/web/package.json
git -C "$g1" commit -qm init
echo '{"dependencies":{"@repo/ui":"workspace:*"}}' > "$g1/apps/web/package.json"
cat > "$g1/pnpm-lock.yaml" <<'LOCK'
importers:
  apps/web:
    dependencies:
      '@repo/ui':
        specifier: workspace:*
        version: link:../../packages/ui
LOCK
git -C "$g1" add pnpm-lock.yaml apps/web/package.json
assert_empty \
    "G-1 正常な workspace 依存の追加では ask が出ない" \
    "$(run_hook 'git commit -m x' "$g1")"

# --- G-1b: lockfile の link: 宣言は引用符付きでも検出する ---
# YAML はパスに空白等があると引用符を付ける。specifier: の直後に link: が来る形だけを見ると
# この形を取り逃す。G-1 の修正が「検査ごと削除する」方向へ倒れていないことも同時に押さえる
g1b="$WORK/g1b"
git_init "$g1b"
mkdir -p "$g1b/apps/web"
cat > "$g1b/pnpm-lock.yaml" <<'LOCK'
importers:
  apps/web:
    dependencies: {}
LOCK
echo '{"dependencies":{}}' > "$g1b/apps/web/package.json"
git -C "$g1b" add pnpm-lock.yaml apps/web/package.json
git -C "$g1b" commit -qm init
cat > "$g1b/pnpm-lock.yaml" <<'LOCK'
importers:
  apps/web:
    dependencies:
      '@x/contract':
        specifier: 'link:../my contract'
        version: link:../my contract
LOCK
git -C "$g1b" add pnpm-lock.yaml
assert_contains \
    "G-1b 引用符付きの specifier: link: を検出する" \
    "$(run_hook 'git commit -m x' "$g1b")" \
    '"permissionDecision": "ask"'

# --- G-2: ドメイン語の draft: で actual: 欠落の error が消えない ---
# draft: をエントリ 1 行目のどこでも拾うと、「ステータスが draft: のまま」のような本文が
# 未実行マーカーと区別できない。F-3（末尾注記）と同じバグクラスの別の表面
g2="$WORK/g2"
mkdir -p "$g2"
cat > "$g2/verification.md" <<'MARKDOWN'
# cap Verification

## Preconditions

## Sub-features

## How to get to it

## Driving it

- [x] 記事を保存する → ステータスが draft: のまま表示される
      Side effect: `SELECT id FROM articles WHERE organization_id = :org;`
      → expected: 1 件

## Gotchas
MARKDOWN
assert_contains \
    "G-2 本文中の draft: で実行済み行の actual: 欠落 error が消えない" \
    "$(node "$LINT" "$g2/verification.md" 2>&1)" \
    'actual: が無い'

# --- G-3 / G-3b / G-4: 基点抽出と git commit 検知の穴 ---
# いずれも「ガードが黙って開く」形。fixture は 1 つを共有する
g3="$WORK/g3"
git_init "$g3"
mkdir -p "$g3/apps/web"
touch "$g3/pnpm-lock.yaml"
echo '{"dependencies":{"@x/contract":"1.0.0"}}' > "$g3/apps/web/package.json"
git -C "$g3" add pnpm-lock.yaml apps/web/package.json
git -C "$g3" commit -qm init
echo '{"dependencies":{"@x/contract":"link:../../../contract"}}' > "$g3/apps/web/package.json"
git -C "$g3" add apps/web/package.json

# git commit より後ろの cd は基点と無関係。これを拾うと base が /tmp に化け、
# 足切りが「pnpm 非使用」と誤判定して fail-closed に到達する前に exit 0 する
assert_contains \
    "G-3 git commit の後ろの cd で基点が上書きされない" \
    "$(run_hook 'git commit -m x && cd /tmp' "$g3")" \
    '"permissionDecision": "ask"'

# 改行区切りのコマンド。grep は行単位、bash [[ =~ ]] は文字列全体で ^ を解釈するため、
# 照合を bash 側へ寄せると複数行コマンドで hook が丸ごとスキップされる。この形を恒久的に固定する
assert_contains \
    "G-3b 改行区切りのコマンドでもガードが働く" \
    "$(run_hook "$(printf 'git commit -m x\ncd /tmp')" "$g3")" \
    '"permissionDecision": "ask"'

# コマンド置換の中の git commit。境界クラスに ( が無いと検知できない
assert_contains \
    "G-4 コマンド置換の中の git commit を検知する" \
    "$(run_hook 'echo $(git commit -m x)' "$g3")" \
    '"permissionDecision": "ask"'

# --- G-5: OR で結合されたテナント述語を warn で拾う ---
# hasTenantFilter は列名と比較演算子の存在しか見ないため、選言に入った organization_id を
# 合格と判定する。error にせず warn にするのは、正当な OR での過剰検知を避けるため
g5="$WORK/g5"
mkdir -p "$g5"
cat > "$g5/verification.md" <<'MARKDOWN'
# cap Verification

## Preconditions

## Sub-features

## How to get to it

## Driving it

- [x] 記事を開く → 本文が表示される
      Side effect: `SELECT id FROM articles WHERE user_id = :u OR organization_id = :org;`
      → actual: 1 件 / expected: 1 件

## Gotchas
MARKDOWN
g5_out="$(node "$LINT" "$g5/verification.md" 2>&1)"
assert_contains \
    "G-5 OR で結合されたテナント述語に warn が出る" \
    "$g5_out" \
    'OR が含まれる'
# 強さの検証。error にすると正当な OR を含むクエリでの過剰検知が警告を読み飛ばす習慣を育てるため、
# warn に留めるという判断そのものをテストで固定する
assert_contains \
    "G-5b OR の指摘は error ではなく warn に留まる" \
    "$g5_out" \
    '0 error / 1 warn'

echo
echo "${pass_count} passed / ${fail_count} failed"
[[ "$fail_count" -eq 0 ]] || exit 1
