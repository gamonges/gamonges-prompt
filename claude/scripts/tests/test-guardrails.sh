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
# 依存: bash / git / jq / node（いずれも本 repo の運用で既に必須）。
# 加えて perl を 1 箇所で使う（link/unlink の中断テストでプロセスグループを分けるため。
# macOS / Linux のいずれにも標準で入っている）

# set -e は使わない。1 件目の失敗で残りが走らなくなると、修正前に「4 件すべてが FAIL する」
# ことを確認できず、TDD の Red フェーズが成立しない
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

HOOK="$REPO_ROOT/claude/scripts/hook-block-local-contract-link.sh"
TMP_HOOK="$REPO_ROOT/claude/scripts/hook-block-tmp-commit.sh"
LINT="$REPO_ROOT/claude/skills/verify-scenario/scripts/verification-lint.mjs"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass_count=0
fail_count=0

pass() { echo -e "${GREEN}[PASS]${NC} $1"; pass_count=$((pass_count + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; fail_count=$((fail_count + 1)); }

for required in "$HOOK" "$TMP_HOOK" "$LINT"; do
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

# hook の exit code を親シェルへ渡す経路。run_hook は $(...) の中で呼ばれてサブシェルで
# 走るため、変数に代入しても親からは読めない。ファイルに書いて assert 側で読む
RC_FILE="$WORK/.last_hook_rc"

# PreToolUse hook は stdin から JSON を受け取る
run_hook_on() {  # $1=hook, $2=command, $3=cwd
    jq -n --arg c "$2" --arg w "$3" '{tool_input:{command:$c},cwd:$w}' | bash "$1" 2>&1
    echo "${PIPESTATUS[1]}" > "$RC_FILE"
}

run_hook() {  # $1=command, $2=cwd（既定の hook を対象にする短縮形）
    run_hook_on "$HOOK" "$1" "$2"
}

run_tmp_hook() {  # $1=command, $2=cwd
    run_hook_on "$TMP_HOOK" "$1" "$2"
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

# PreToolUse hook では exit code が挙動を決める（0 = JSON で判断、2 = 無条件ブロック、
# その他 = non-blocking エラー）。出力だけを見ると、exit 2 へのハードブロック化や
# 無出力クラッシュへの退行を捕まえられない。hook を起動した assertion では rc も固定する。
# lint を対象にする assert_contains と分けているのは、lint 実行では RC_FILE が更新されず
# 前回の hook の値が残るため
assert_hook_rc() {  # $1=ラベル（失敗時の表示用）
    local rc
    rc=$(cat "$RC_FILE" 2>/dev/null || echo "?")
    if [[ "$rc" == "0" ]]; then
        return 0
    fi
    echo "       hook の exit code が 0 ではない: $rc" >&2
    return 1
}

assert_hook_contains() {  # $1=ラベル, $2=実出力, $3=期待する部分文字列
    if [[ "$2" == *"$3"* ]] && assert_hook_rc "$1"; then
        pass "$1"
    else
        fail "$1"
        echo "       期待する部分文字列: $3" >&2
        echo "       実際の出力: ${2:-（出力なし）}" >&2
    fi
}

assert_hook_empty() {  # $1=ラベル, $2=実出力
    if [[ -z "$2" ]] && assert_hook_rc "$1"; then
        pass "$1"
    else
        fail "$1"
        echo "       出力が無いことを期待した。実際の出力: ${2:-（出力なし）}" >&2
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
assert_hook_contains \
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
assert_hook_contains \
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
assert_hook_empty \
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
assert_hook_contains \
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
assert_hook_contains \
    "G-3 git commit の後ろの cd で基点が上書きされない" \
    "$(run_hook 'git commit -m x && cd /tmp' "$g3")" \
    '"permissionDecision": "ask"'

# 改行区切りのコマンド。grep は行単位、bash [[ =~ ]] は文字列全体で ^ を解釈するため、
# 照合を bash 側へ寄せると複数行コマンドで hook が丸ごとスキップされる。この形を恒久的に固定する
assert_hook_contains \
    "G-3b 改行区切りのコマンドでもガードが働く" \
    "$(run_hook "$(printf 'git commit -m x\ncd /tmp')" "$g3")" \
    '"permissionDecision": "ask"'

# コマンド置換の中の git commit。境界クラスに ( が無いと検知できない
assert_hook_contains \
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

# --- C-7 / M-8 / M-9: verification-lint のスコープ誤り ---
# いずれも「error が黙って消える」形。F-3 / G-2 が draft: について塞いだのと同じ
# バグクラスが、兄弟のチェックに残っていた
lintdir="$WORK/lint"
mkdir -p "$lintdir"

write_verification() {  # $1=出力先, $2=Driving it の中身（heredoc で渡す）
    { printf '# cap Verification\n\n## Preconditions\n\n## Sub-features\n\n## How to get to it\n\n## Driving it\n\n'
      cat
      printf '\n## Gotchas\n'
    } > "$1"
}

# C-7: 1 行に Side effect: が 2 本あるとき、no-tenant-filter: は 1 本目にしか係らない。
# 正典（verification-format.md）は「その 1 本の SQL だけ」と定めており、行単位にすると
# 「1 本の逃げ道が同エントリの他の SQL の検査まで外す」という、正典が明示的に退けた
# 失敗モードが粒度を 1 段落としただけで再現する
write_verification "$lintdir/c7.md" <<'MD'
- [x] 監査ログと全件を確認 → 表示される
      Side effect: `SELECT COUNT(*) FROM audit_logs;` / no-tenant-filter: 監査ログはテナント横断 / Side effect: `SELECT id FROM everything;`
      → actual: `1` / expected: 1
MD
assert_contains "C-7 1 行の 2 本目の Side effect: は no-tenant-filter: の対象外（テナント error が出る）" \
    "$(node "$LINT" "$lintdir/c7.md" 2>&1)" \
    'organization_id の絞り込みが無い'

# 記入例の形（1 行 1 本 + マーカー）が引き続き免除されることも固定する。
# セグメント分割が過剰に効いて正当な免除まで外すと、テナント検査が「常に error」になり
# 読み飛ばす習慣を育てる（過剰検知は fail-open とは逆方向から検査を殺す）
write_verification "$lintdir/c7ok.md" <<'MD'
- [x] 監査ログを確認 → 表示される
      Side effect: `SELECT COUNT(*) FROM audit_logs;` / no-tenant-filter: 監査ログはテナント横断
      → actual: `3` / expected: 3
MD
assert_contains "C-7b 記入例の形（1 行 1 本 + マーカー）は従来どおり免除される" \
    "$(node "$LINT" "$lintdir/c7ok.md" 2>&1)" \
    '0 error / 0 warn'

# M-9: バッククォート欠落があると sqls と noTenantFlags の添字がずれ、
# マーカーが別の SQL に対して適用される。利用者に見えるのは「バッククォートで囲まれていない」
# という別の error だけなので、それを直すまでテナント違反が隠れる
write_verification "$lintdir/m9.md" <<'MD'
- [x] 監査ログと全件を確認 → 表示される
      Side effect: SELECT COUNT(*) FROM audit_logs; / no-tenant-filter: 監査ログはテナント横断
      Side effect: `SELECT id FROM everything;`
      → actual: `1` / expected: 1
MD
assert_contains "M-9 バッククォート欠落で添字がずれてもテナント error が消えない" \
    "$(node "$LINT" "$lintdir/m9.md" 2>&1)" \
    'organization_id の絞り込みが無い'

# M-8: expected: / actual: の存在検査が entry.text 全体に当たるため、エントリの後に
# 空行 1 つを挟んで置いた散文で満たされてしまう（最後のエントリには次の ## 見出しまでが連結される）
write_verification "$lintdir/m8.md" <<'MD'
- [x] 保存する → 一覧に反映される
      Side effect: `SELECT id FROM orders WHERE organization_id = :org;`
      → expected: 1 件

注: 実行したら actual: を転記する
MD
assert_contains "M-8 エントリ外の散文にある actual: では欠落 error が消えない" \
    "$(node "$LINT" "$lintdir/m8.md" 2>&1)" \
    'actual: が無い'

# M-8 の修正（空行でエントリを閉じる）が新しく作る表面。閉じた後に置かれた Side effect: を
# 黙って無検査にすると、テナント検査に穴が開く。書式違反として明示的に落とす
write_verification "$lintdir/m8b.md" <<'MD'
- [x] 保存する → 一覧に反映される
      Side effect: `SELECT id FROM orders WHERE organization_id = :org;`
      → actual: 1 件 / expected: 1 件

      Side effect: `SELECT id FROM everything;`
MD
assert_contains "M-8b 空行で区切った 2 ブロック目は無検査にせず書式違反として落とす" \
    "$(node "$LINT" "$lintdir/m8b.md" 2>&1)" \
    'エントリへ属さない行'

# 正典の記入例が引き続き lint を通ることを固定する（後方互換の判定基準）。
# エントリ境界の変更で分割数が変わっていないことの直接的な証拠になる
# 「## 記入例」以降の最初のコードフェンスを取る。ファイル冒頭にもテンプレートの
# コードフェンスがあるため、範囲指定だけだと両方を連結して拾ってしまう
FORMAT_MD="$REPO_ROOT/claude/skills/verify-scenario/reference/verification-format.md"
awk '/^## 記入例/{s=1} s && /^````markdown$/{f=1;next} s && f && /^````$/{exit} s && f{print}' \
    "$FORMAT_MD" > "$lintdir/verification.md"
assert_contains "C-7c 正典の記入例は 0 error / 1 warn（draft: 1 件）を維持する" \
    "$(node "$LINT" "$lintdir/verification.md" 2>&1)" \
    '0 error / 1 warn'

# --- C-2 / C-3 / M-1〜M-5: git commit の検知境界とスコープ判定 ---
# fixture は g3 を共有する（link: を staged した pnpm リポジトリ）。
# 以下はいずれも「ガードが黙って開く」形で、直上のコメントが防げると主張している形を含む
c23="$WORK/c23"
git_init "$c23"
mkdir -p "$c23/apps/web"
touch "$c23/pnpm-lock.yaml"
echo '{"dependencies":{"@x/contract":"1.0.0"}}' > "$c23/apps/web/package.json"
git -C "$c23" add pnpm-lock.yaml apps/web/package.json
git -C "$c23" commit -qm init
echo '{"dependencies":{"@x/contract":"link:../../../contract"}}' > "$c23/apps/web/package.json"
git -C "$c23" add apps/web/package.json

# C-2: commit の直後が空白でも行末でもない形。GIT_COMMIT_RE の末尾境界が
# ([[:space:]]|$) だけだと ) ; & で終わる形を取り逃す。
# 「含めないと echo $(git commit) が素通しする」というコメントが名指しした形そのものが
# 素通ししていた（引数なしだと commit の直後が ) になるため）
assert_hook_contains "C-2a コマンド置換 echo \$(git commit) を検知する（引数なし）" \
    "$(run_hook 'echo $(git commit)' "$c23")" '"permissionDecision": "ask"'
assert_hook_contains "C-2b サブシェル ( cd repo && git commit ) を検知する" \
    "$(run_hook "(cd $c23 && git commit)" "$c23")" '"permissionDecision": "ask"'
assert_hook_contains "C-2c セミコロン直後で終わる git commit; を検知する" \
    "$(run_hook 'git commit;' "$c23")" '"permissionDecision": "ask"'
assert_hook_contains "C-2d git commit; echo ok を検知する" \
    "$(run_hook 'git commit; echo ok' "$c23")" '"permissionDecision": "ask"'

# C-3: git の直前にトークンがある形。先頭境界が (^|[;&|(`]) だと素通しする。
# 1 つ目はこのテストファイル自身が fixture 生成に使っている形
assert_hook_contains "C-3a 環境変数を前置した git commit を検知する" \
    "$(run_hook 'GIT_AUTHOR_DATE=2020-01-01 git commit -m y' "$c23")" '"permissionDecision": "ask"'
assert_hook_contains "C-3b if-then の中の git commit を検知する" \
    "$(run_hook 'if true; then git commit -m x; fi' "$c23")" '"permissionDecision": "ask"'
assert_hook_contains "C-3c sudo git commit を検知する" \
    "$(run_hook 'sudo git commit -m x' "$c23")" '"permissionDecision": "ask"'

# 先頭境界を緩めると偽陽性が増えるため、拾ってはいけない形も固定する
assert_hook_empty "C-3d git add foo commit は検知しない（偽陽性の回帰）" \
    "$(run_hook 'git add foo commit' "$c23")"
assert_hook_empty "C-3e 語中の agit commit は検知しない（偽陽性の回帰）" \
    "$(run_hook 'echo agit commit' "$c23")"

# M-2: バックスラッシュでエスケープした空白を含むパス。bash で最も普通の書き方だが
# PATH_ARG の候補に無いため、-C の引数を途中で切って基点解決が壊れる
m2="$WORK/m2 space"
git_init "$m2"
mkdir -p "$m2/apps/web"
touch "$m2/pnpm-lock.yaml"
echo '{"dependencies":{"@x/contract":"1.0.0"}}' > "$m2/apps/web/package.json"
git -C "$m2" add pnpm-lock.yaml apps/web/package.json
git -C "$m2" commit -qm init
echo '{"dependencies":{"@x/contract":"link:../../../contract"}}' > "$m2/apps/web/package.json"
git -C "$m2" add apps/web/package.json
assert_hook_contains "M-2 -C のパスがバックスラッシュエスケープ空白でも検知する" \
    "$(run_hook "git -C ${m2// /\\ } commit -m x" "$WORK")" '"permissionDecision": "ask"'

# M-1: && で連結された 2 本目の git commit。先頭一致だけを使うと、1 本目が非 pnpm
# リポジトリのときに足切りで exit 0 し、2 本目が守るべきリポジトリでも素通しする
m1_other="$WORK/m1-other"
git_init "$m1_other"
assert_hook_contains "M-1 && で連結された 2 本目の git commit も検査する" \
    "$(run_hook "git -C $m1_other commit -m a && git -C $c23 commit -m b" "$WORK")" \
    '"permissionDecision": "ask"'

# M-3: コミットメッセージ本文の -a に誤爆して scope が diff HEAD に化ける（過剰検知）。
# link: は unstaged のままにするので、ask が出たら誤爆の証拠
m3="$WORK/m3"
git_init "$m3"
mkdir -p "$m3/apps/web"
touch "$m3/pnpm-lock.yaml"
echo '{"dependencies":{"@x/contract":"1.0.0"}}' > "$m3/apps/web/package.json"
git -C "$m3" add pnpm-lock.yaml apps/web/package.json
git -C "$m3" commit -qm init
echo '{"dependencies":{"@x/contract":"link:../../../contract"}}' > "$m3/apps/web/package.json"
assert_hook_empty "M-3 メッセージ本文の -a では scope が diff HEAD に化けない（過剰検知の回帰）" \
    "$(run_hook 'git commit -m "fix -a flag handling"' "$m3")"
assert_hook_contains "M-3b 実際の -am は従来どおり検知する" \
    "$(run_hook 'git commit -am x' "$m3")" '"permissionDecision": "ask"'

# M-5: lockfile 検査の対象範囲は pnpm 8+ の形式（specifier: 単数）に限る。
# v6-v7 の specifiers:（複数形）マップは意図的に対象外にしており、その判断が
# 「検出を足そう」として崩されないよう、崩すと何が起きるかを固定する。
#
# v6-v7 では正常な workspace 依存も dependencies: セクションで link: を値に取る:
#     specifiers:
#       '@repo/ui': workspace:*        ← 宣言はこちら
#     dependencies:
#       '@repo/ui': link:../packages/ui  ← 解決結果。これは事故ではない
# 行単位の grep はセクションを判別できないため、'name': link: を拾うパターンを足すと
# 正常な workspace 依存で ask が出る。G-1 で直したばかりの過剰検知と同型になる。
# v6-v7 でも pnpm link は package.json を書き換えるので、そちらの検査で捕まる
m5="$WORK/m5"
git_init "$m5"
mkdir -p "$m5/apps/web" "$m5/packages/ui"
cat > "$m5/pnpm-lock.yaml" <<'LOCK'
lockfileVersion: 5.4
importers:
  apps/web:
    specifiers: {}
LOCK
echo '{"dependencies":{}}' > "$m5/apps/web/package.json"
git -C "$m5" add pnpm-lock.yaml apps/web/package.json
git -C "$m5" commit -qm init
echo '{"dependencies":{"@repo/ui":"workspace:*"}}' > "$m5/apps/web/package.json"
cat > "$m5/pnpm-lock.yaml" <<'LOCK'
lockfileVersion: 5.4
importers:
  apps/web:
    specifiers:
      '@repo/ui': workspace:*
    dependencies:
      '@repo/ui': link:../../packages/ui
LOCK
git -C "$m5" add pnpm-lock.yaml apps/web/package.json
assert_hook_empty "M-5 pnpm v6-v7 形式の正常な workspace 依存では ask が出ない（過剰検知の回帰）" \
    "$(run_hook 'git commit -m x' "$m5")"

# --- T-1〜T-9: tmp/ コミット禁止ガード（hook-block-tmp-commit.sh） ---
# このスクリプトは判定を 8 箇所書き換えるため、fail-open（T-8 / T-9）だけでなく
# 正常系（T-1〜T-7）も固定する。過剰検知（deny が出なくなる / 出すぎる）は fail-open とは
# 逆方向から同じくガードを無効化するので、書き換えの前後で不変であることを見る必要がある。
# T-1〜T-7 は書き換え前の実測値をそのまま期待値にしている
t_dir="$WORK/tmpguard"
mkdir -p "$t_dir"

assert_hook_contains "T-1 tmp/ 配下の git add を deny する" \
    "$(run_tmp_hook 'git add tmp/x.txt' "$t_dir")" '"permissionDecision": "deny"'

assert_hook_empty "T-2 tmp/ 以外の git add は素通しする" \
    "$(run_tmp_hook 'git add src/x.ts' "$t_dir")"

# pathspec exclusion。該当箇所は「tmp/ を含む」かつ「:!tmp/ を含まない」の複合条件で、
# 判定をヘルパー化するときに否定側を取り違えると、除外指定が静かに効かなくなる
assert_hook_empty "T-3 pathspec exclusion (:!tmp/) は素通しする" \
    "$(run_tmp_hook 'git add tmp/x.txt :!tmp/' "$t_dir")"

assert_hook_contains "T-4 git add . を deny する" \
    "$(run_tmp_hook 'git add .' "$t_dir")" '"permissionDecision": "deny"'

assert_hook_contains "T-5 git add -A を deny する" \
    "$(run_tmp_hook 'git add -A' "$t_dir")" '"permissionDecision": "deny"'

assert_hook_contains "T-6 git add --all を deny する" \
    "$(run_tmp_hook 'git add --all' "$t_dir")" '"permissionDecision": "deny"'

assert_hook_empty "T-7 git add 以外のコマンドは素通しする" \
    "$(run_tmp_hook 'git commit -m x' "$t_dir")"

# T-8: 改行を含む大きな COMMAND。git add 判定の grep -q が SIGPIPE で死んで rc=141 になり、
# `if !` が真になって exit 0 する。head -1 の箇所とは別経路で、複合コマンド（heredoc を含む形）
# で到達するためこちらのほうが現実的
t_pad=$(i=0; while [[ $i -lt 12000 ]]; do echo "# padding"; i=$((i + 1)); done)
assert_hook_contains "T-8 改行入り 120 KB の COMMAND でも tmp/ の git add を deny する" \
    "$(run_tmp_hook "$(printf 'git add tmp/x.txt\n%s' "$t_pad")" "$t_dir")" \
    '"permissionDecision": "deny"'

# T-9: ; 区切りの git add を多数並べると、引数抽出の grep -oE | head -1 で head が
# 早期終了して書き手が SIGPIPE で死ぬ
t_many=$(i=0; while [[ $i -lt 4000 ]]; do printf 'git add tmp/f%d.txt; ' "$i"; i=$((i + 1)); done)
assert_hook_contains "T-9 ; 区切り 4,000 句でも tmp/ の git add を deny する" \
    "$(run_tmp_hook "$t_many" "$t_dir")" \
    '"permissionDecision": "deny"'

# --- F-5: 変更ファイルが多い commit でもガードが働く（SIGPIPE + pipefail の回帰） ---
# grep -q は最初のマッチで終了する。書き込み側（git）がまだ書いている途中だと SIGPIPE で
# 死んで exit 141 を返し、pipefail 下ではパイプライン全体が 141 になる。マッチしていても
# if が偽になり ask が出ない。「echo は builtin だから安全」は誤りで、bash はパイプラインの
# builtin もサブシェルとして fork するため同じく SIGPIPE を受ける。
#
# 3,000 件で --name-only が約 88 KB になり、パイプバッファ（macOS: 65,536 B）を超える。
# 2,000 件では 58,912 B にしかならず閾値に届かないため、修正前でも ASK が出て Red にならない。
# ファイル数だけでなくサイズを条件に持つことが本質なので、パス名を短くする変更を入れる際は
# --name-only のバイト数を測り直すこと
f5="$WORK/f5"
git_init "$f5"
mkdir -p "$f5/apps/web" "$f5/zz"
touch "$f5/pnpm-lock.yaml"
echo '{"dependencies":{"@x/contract":"1.0.0"}}' > "$f5/apps/web/package.json"
git -C "$f5" add pnpm-lock.yaml apps/web/package.json
git -C "$f5" commit -qm init
echo '{"dependencies":{"@x/contract":"link:../../../contract"}}' > "$f5/apps/web/package.json"
i=0
while [[ $i -lt 3000 ]]; do : > "$f5/zz/padding-file-name-$i.txt"; i=$((i + 1)); done
git -C "$f5" add zz apps/web/package.json
assert_hook_contains \
    "F-5 変更ファイル 3,000 件（--name-only 約 88 KB）でも link: を検知する" \
    "$(run_hook 'git commit -m x' "$f5")" \
    '"permissionDecision": "ask"'

# =====================================================================
# link-contract.sh / unlink-contract.sh の挙動テスト（H-1〜H-7）
# =====================================================================
# この 2 本は実 pnpm と実リポジトリを触るため、テストからは疑似 pnpm を PATH 先頭に差して
# 決定論的に動かす。再現するモデルは 2 つあり、既定は実 pnpm 11.15.1 の実測挙動:
#
#   PNPM_MODEL=v11 (既定) — app の package.json は書き換えず、FRONTEND_DIR 直下の
#                           package.json に link: を書き、pnpm-workspace.yaml に overrides を書く
#   PNPM_MODEL=v9         — app の package.json を link: に書き換える（script が当初想定したモデル）
#   PNPM_MODEL=nothing    — tracked file を 1 つも変えず pnpm-workspace.yaml だけを新規作成する
#                           （非 workspace 形状。第一ガードを張る対象が存在しない）
#
# PNPM_FAIL_ON=<step>  指定ステップで非ゼロ終了する（build / link / link-mid / unlink / install）
#   link-mid は「manifest を書いた後に落ちる」ケースで、残骸の扱いを見るために分けている

LINK_SH="$REPO_ROOT/claude/scripts/link-contract.sh"
UNLINK_SH="$REPO_ROOT/claude/scripts/unlink-contract.sh"

FAKE_BIN="$WORK/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/pnpm" <<'FAKEPNPM'
#!/usr/bin/env bash
# テスト用の疑似 pnpm。実 pnpm 11.15.1 の実測挙動を既定モデルとして再現する
set -uo pipefail
model="${PNPM_MODEL:-v11}"
fail_on="${PNPM_FAIL_ON:-}"

die_if() {  # $1=step
    if [[ "${PNPM_SIGINT_ON:-}" == "$1" ]]; then
        # プロセスグループ全体へ SIGINT を送る。$PPID（呼び出し元のサブシェル）だけに送っても
        # `if ! ( … pnpm unlink )` の条件部なので script は「失敗」として WARN を出して復元まで
        # 進んでしまい、「復元前に中断した」状況にならない。
        # 呼び出し側が setpgrp でプロセスグループを分けているので、テスト本体には届かない
        echo "[fakepnpm] SIGINT at $1" >&2
        kill -INT 0 2>/dev/null || true
        exit 130
    fi
    if [[ "$fail_on" == "$1" ]]; then
        echo "[fakepnpm] FAIL at $1" >&2
        exit 3
    fi
}

case "${1:-}" in
  --filter)  # pnpm --filter <pkg> run build
    die_if build
    echo "[fakepnpm] build ok"
    ;;
  link)  # pnpm link <path> — cwd は APP_DIR
    die_if link
    target="${2:-}"
    # FRONTEND_DIR は APP_DIR の親をたどって pnpm-lock.yaml がある場所とする
    root="$PWD"
    while [[ "$root" != "/" && ! -f "$root/pnpm-lock.yaml" ]]; do root="$(dirname "$root")"; done
    case "$model" in
      v9)
        # app の package.json を書き換える（script が当初想定したモデル）
        node -e '
          const fs = require("fs");
          const p = process.argv[1], t = process.argv[2];
          const j = JSON.parse(fs.readFileSync(p, "utf-8"));
          j.dependencies = j.dependencies || {};
          j.dependencies["@x/contract"] = "link:" + t;
          fs.writeFileSync(p, JSON.stringify(j));
        ' "$PWD/package.json" "$target"
        printf 'lockfileVersion: 9.0\nimporters:\n  .:\n    dependencies:\n      %s\n' \
            "'@x/contract': { specifier: link:$target, version: link:$target }" > "$root/pnpm-lock.yaml"
        ;;
      nothing)
        # tracked file を 1 つも変えない。pnpm-workspace.yaml だけを新規作成する
        printf 'packages:\n  - "apps/*"\noverrides:\n  "@x/contract": link:%s\n' "$target" \
            > "$root/pnpm-workspace.yaml"
        ;;
      *)  # v11
        node -e '
          const fs = require("fs");
          const p = process.argv[1], t = process.argv[2];
          const j = JSON.parse(fs.readFileSync(p, "utf-8"));
          j.dependencies = j.dependencies || {};
          j.dependencies["@x/contract"] = "link:" + t;
          fs.writeFileSync(p, JSON.stringify(j));
        ' "$root/package.json" "$target"
        printf 'packages:\n  - "apps/*"\noverrides:\n  "@x/contract": link:%s\n' "$target" \
            > "$root/pnpm-workspace.yaml"
        ;;
    esac
    die_if link-mid
    echo "[fakepnpm] link ok ($model)"
    ;;
  unlink)
    die_if unlink
    echo "[fakepnpm] unlink ok"
    ;;
  install)
    die_if install
    echo "[fakepnpm] install ok"
    ;;
  *)
    echo "[fakepnpm] unhandled: $*" >&2
    ;;
esac
exit 0
FAKEPNPM
chmod +x "$FAKE_BIN/pnpm"

# link/unlink の fixture を作る。frontend は pnpm workspace 形状（apps/web に exact pin）、
# backend は contract パッケージを持つだけの最小構成
make_link_fixture() {  # $1=fixture ディレクトリ
    local d="$1"
    git_init "$d/frontend"
    mkdir -p "$d/frontend/apps/web" "$d/backend/packages/contract"
    printf '{"name":"fe-root","private":true}\n' > "$d/frontend/package.json"
    printf 'packages:\n  - "apps/*"\n' > "$d/frontend/pnpm-workspace.yaml"
    printf '{"dependencies":{"@x/contract":"1.0.0"}}\n' > "$d/frontend/apps/web/package.json"
    printf 'lockfileVersion: 9.0\n' > "$d/frontend/pnpm-lock.yaml"
    printf '{"name":"@x/contract","version":"1.0.0"}\n' > "$d/backend/packages/contract/package.json"
    git -C "$d/frontend" add package.json pnpm-workspace.yaml pnpm-lock.yaml apps/web/package.json
    git -C "$d/frontend" commit -qm init
}

# link/unlink を疑似 pnpm 環境で実行する。出力と exit code を返す（rc は RC_FILE 経由）
run_contract_sh() {  # $1=script, $2=fixture ディレクトリ, 以降 KEY=VALUE の環境変数
    local script="$1" d="$2"; shift 2
    ( export PATH="$FAKE_BIN:$PATH" \
             BACKEND_DIR="$d/backend" \
             FRONTEND_DIR="$d/frontend" \
             CONTRACT_PKG="@x/contract" \
             CONTRACT_PKG_DIR="packages/contract" \
             CONTRACT_APP_PKG_JSON="apps/web/package.json" \
             CONTRACT_REGISTRY_TOKEN_VAR=""
      for kv in "$@"; do export "${kv?}"; done
      # PNPM_SIGINT_ON を使うケースだけプロセスグループを分ける。疑似 pnpm が kill -INT 0 で
      # グループ全体へ送るため、分けないとテスト本体まで落ちる
      if [[ -n "${PNPM_SIGINT_ON:-}" ]]; then
        perl -e 'setpgrp(0,0); exec @ARGV' bash "$script" 2>&1
      else
        bash "$script" 2>&1
      fi )
    echo "$?" > "$RC_FILE"
}

# --- H-3 / H-4: happy path（実 pnpm 11 のモデルで link → unlink が完結する） ---
# 実 pnpm 11 は app の package.json を書き換えず、root の package.json と pnpm-workspace.yaml に
# 書く。保護対象がそれを捉えていないと、link 後に dirty が残り unlink が正常系で失敗する
h34="$WORK/h34"
make_link_fixture "$h34"
h34_out="$(run_contract_sh "$LINK_SH" "$h34")"
assert_hook_contains "H-3a link-contract.sh が exit 0 で完了する（pnpm 11 モデル）" \
    "$h34_out" "link 完了"
assert_empty "H-3b link 完了後に git status が clean（保護対象が実挙動と一致している）" \
    "$(git -C "$h34/frontend" status --porcelain)"

h34_un="$(run_contract_sh "$UNLINK_SH" "$h34")"
assert_hook_contains "H-4 link → unlink が exit 0 で完了し link: が残らない" \
    "$h34_un" "unlink 完了"

# --- H-1: pnpm link が manifest を書いた後に失敗したとき、再実行の案内が正しい ---
# 「先に commit / stash する」と案内すると、dirty の正体が link: そのものなので、
# ガードレール自身が防ごうとしている事故を指示することになる
#
# 期待値を「unlink-contract.sh を含む」にすると偽陽性になる（残骸を検出できず再実行が
# 成功したときの完了メッセージ「解除: bash …/unlink-contract.sh」に偶然マッチする）。
# 中断することまで固定する。
#
# H-1a: 第一ガードを pnpm link の前に張る設計では、link が途中で落ちても
#       skip-worktree が残る。再実行はそれを検出して止まらなければならない
h1="$WORK/h1"
make_link_fixture "$h1"
run_contract_sh "$LINK_SH" "$h1" "PNPM_FAIL_ON=link-mid" >/dev/null
h1_retry="$(run_contract_sh "$LINK_SH" "$h1")"
assert_contains "H-1a link が途中で落ちた後の再実行は skip-worktree の残存を検出して中断する" \
    "$h1_retry" "skip-worktree が既に立っている"

# H-1b: 第一ガードが張られていない状態で保護対象が dirty かつ link: を含む形。
#       ここで「先に commit / stash する」と案内すると、dirty の正体が link: そのものなので、
#       ガードレール自身が防ごうとしている事故を指示することになる
h1b="$WORK/h1b"
make_link_fixture "$h1b"
printf '{"dependencies":{"@x/contract":"link:../../../backend/packages/contract"}}\n' \
    > "$h1b/frontend/apps/web/package.json"
h1b_out="$(run_contract_sh "$LINK_SH" "$h1b")"
assert_contains "H-1b link: を含む dirty には commit / stash ではなく復元を案内する" \
    "$h1b_out" "commit / stash してはいけない"

# --- H-2: unlink を復元前に失敗させたとき、第一ガードが再武装される ---
# skip-worktree を落としてから checkout までの窓で落ちると、link 完了状態から
# ガードだけ剥がれた状態が残り、git add / commit -a / IDE のどれからでも巻き込める
#
# 中断は SIGINT で作る。pnpm unlink の失敗（PNPM_FAIL_ON）では現行実装が WARN を出して
# 復元まで進んでしまい、「復元前に落ちる」状況にならない（= Red が作れない）
h2="$WORK/h2"
make_link_fixture "$h2"
run_contract_sh "$LINK_SH" "$h2" >/dev/null
run_contract_sh "$UNLINK_SH" "$h2" "PNPM_SIGINT_ON=unlink" >/dev/null
# 判定は「S 行が 1 件以上あるか」を直接見る。assert_contains に期待値 "S " を渡す形では、
# 空のときに使うプレースホルダ文字列（「S フラグが…」）自身が期待値を含んでしまい偽陽性になった
h2_label="H-2 unlink が復元前に中断しても skip-worktree が残る（ガードの再武装）"
h2_flags="$(git -C "$h2/frontend" ls-files -v | /usr/bin/grep -c '^S' || true)"
if [[ "${h2_flags:-0}" -gt 0 ]]; then
    pass "$h2_label"
else
    fail "$h2_label"
    echo "       skip-worktree が 1 件も残っていない = 第一ガードが剥がれたまま放置される" >&2
fi

# --- H-5: link していない repo で unlink すると、無関係な変更を破棄せず止まる ---
# :L72 の無条件 checkout は、link していない状態では作業中の変更を無言で破棄して
# 「完了」と報告する。損失は非可逆
h5="$WORK/h5"
make_link_fixture "$h5"
printf '{"dependencies":{"@x/contract":"1.0.0"},"scripts":{"dev":"vite"}}\n' > "$h5/frontend/apps/web/package.json"
h5_out="$(run_contract_sh "$UNLINK_SH" "$h5")"
assert_contains "H-5a link していない repo での unlink は非ゼロ終了する" \
    "$h5_out" "link"
assert_contains "H-5b その際に無関係な未コミット変更を破棄しない" \
    "$(cat "$h5/frontend/apps/web/package.json")" '"dev"'

# --- H-6: pnpm-workspace.yaml の overrides: link: を 2 枚目のガードが拾う ---
# 非 workspace 形状では第一ガードが張れないため、hook が唯一の防御になる
h6="$WORK/h6"
git_init "$h6"
mkdir -p "$h6/apps/web"
printf 'lockfileVersion: 9.0\n' > "$h6/pnpm-lock.yaml"
printf 'packages:\n  - "apps/*"\n' > "$h6/pnpm-workspace.yaml"
echo '{"dependencies":{}}' > "$h6/apps/web/package.json"
git -C "$h6" add pnpm-lock.yaml pnpm-workspace.yaml apps/web/package.json
git -C "$h6" commit -qm init
printf 'packages:\n  - "apps/*"\noverrides:\n  "@x/contract": link:../../backend/packages/contract\n' \
    > "$h6/pnpm-workspace.yaml"
git -C "$h6" add pnpm-workspace.yaml
assert_hook_contains "H-6 pnpm-workspace.yaml の overrides: link: を hook が検知する" \
    "$(run_hook 'git commit -m x' "$h6")" '"permissionDecision": "ask"'

# --- H-7: 第一ガードを張る対象が無いとき、その事実を出力する ---
# 非 workspace 形状では pnpm が tracked file を 1 つも変えないため skip-worktree を張れない。
# 静かに無防備になるより、2 枚目の hook のみが防御になることを明示する
#
# 期待値を「第一ガード」にすると、現行の成功メッセージ（「skip-worktree を設定した
# （誤コミットの第一ガード）」）に偶然マッチして偽陽性になる。警告固有の語で固定する
#
# fixture では pnpm-workspace.yaml を commit しない。commit してしまうと skip-worktree を
# 張れてしまい、「張る対象が無い」状況にならない（= Red が作れない）
h7="$WORK/h7"
make_link_fixture "$h7"
git -C "$h7/frontend" rm -q --cached pnpm-workspace.yaml
git -C "$h7/frontend" commit -qm "untrack pnpm-workspace.yaml"
rm -f "$h7/frontend/pnpm-workspace.yaml"
h7_out="$(run_contract_sh "$LINK_SH" "$h7" "PNPM_MODEL=nothing")"
assert_contains "H-7 保護対象が 1 つも tracked でないとき第一ガードを張れないと警告する" \
    "$h7_out" "第一ガードを張れなかった"

echo
echo "${pass_count} passed / ${fail_count} failed"
[[ "$fail_count" -eq 0 ]] || exit 1
