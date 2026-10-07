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
# 本ファイルは shared/scripts/ 直下ではなく tests/ に置く。setup.sh の install_scripts()、
# verify-skills.sh、hook-check-scripts-sync.sh はいずれも shared/scripts/*.sh を glob するため、
# サブディレクトリなら配布・同期検査・orphan 検査のすべてから外れる。実行権限も付かないので
# `bash shared/scripts/tests/test-guardrails.sh` で起動する。
#
# 依存: bash / git / jq / node（いずれも本 repo の運用で既に必須）。
# 加えて perl を 1 箇所で使う（link/unlink の中断テストでプロセスグループを分けるため。
# macOS / Linux のいずれにも標準で入っている）

# set -e は使わない。1 件目の失敗で残りが走らなくなると、修正前に「4 件すべてが FAIL する」
# ことを確認できず、TDD の Red フェーズが成立しない
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

HOOK="$REPO_ROOT/shared/scripts/hook-block-local-contract-link.sh"
TMP_HOOK="$REPO_ROOT/shared/scripts/hook-block-tmp-commit.sh"
CONFIRM_HOOK="$REPO_ROOT/shared/scripts/hook-confirm-destructive-git.sh"
LINT="$REPO_ROOT/shared/skills/verify-scenario/scripts/verification-lint.mjs"
ORPHAN="$REPO_ROOT/shared/skills/worktree-cleanup/scripts/find-orphan-collections.mjs"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass_count=0
fail_count=0

pass() { echo -e "${GREEN}[PASS]${NC} $1"; pass_count=$((pass_count + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; fail_count=$((fail_count + 1)); }

for required in "$HOOK" "$TMP_HOOK" "$LINT" "$ORPHAN"; do
    if [[ ! -f "$required" ]]; then
        echo "test-guardrails.sh: 検査対象が見つからない: $required" >&2
        exit 2
    fi
done

WORK="$(mktemp -d)"
# trap … EXIT は追加ではなく置き換えなので、後始末は 1 つの関数にまとめる。
# 別々に張ると、一時ディレクトリの削除か Milvus スタブの kill のどちらかが黙って消える
STUB_PID=""
cleanup() {
    if [[ -n "$STUB_PID" ]]; then
        kill "$STUB_PID" 2>/dev/null
    fi
    # W-17 が権限を落としたディレクトリが残っていると rm -rf が黙って失敗する
    chmod -R u+rwx "$WORK" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

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

assert_not_contains() {  # $1=ラベル, $2=実出力, $3=含まれてはいけない部分文字列
    if [[ "$2" != *"$3"* ]]; then
        pass "$1"
    else
        fail "$1"
        echo "       含まれてはいけない部分文字列: $3" >&2
        echo "       実際の出力: $2" >&2
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
FORMAT_MD="$REPO_ROOT/shared/skills/verify-scenario/reference/verification-format.md"
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

# --- T-10〜T-21: wrapper とグローバルオプション付きの git ---
# git とサブコマンドの間のグローバルオプション（git -C <path> add）・-c を束ねたシェル（bash -lc・sh -ce）で
# ガードをすり抜けない。直接の git add の deny は wrapper の ask より先に判定する（ask に弱めない）
t_expect() {  # $1=ラベル, $2=期待（deny|ask|pass）, $3=command, $4=hook（既定は tmp-commit）
    local out
    out="$(run_hook_on "${4:-$TMP_HOOK}" "$3" "$t_dir")"
    case "$2" in
        pass) assert_hook_empty "$1" "$out" ;;
        *) assert_hook_contains "$1" "$out" "\"permissionDecision\": \"$2\"" ;;
    esac
}
t_expect "T-10 git -C <path> add tmp/… を deny する" deny 'git -C /repo add tmp/plan.md'
t_expect "T-11 複数行の 2 行目の git -C <path> add tmp/… を deny する" deny "$(printf 'echo hi\ngit -C /r add tmp/x')"
t_expect "T-12 git -C . add src/… は素通しする（-C の引数 . を git add . と取り違えない）" pass 'git -C . add src/x.ts'
for w in "bash -lc 'git add foo'" "/bin/bash -c 'git add foo'" "zsh -lc 'git add foo'" "sh -c 'git add foo'"; do
    t_expect "T-13 git add を運ぶ wrapper（${w%% \'*}）は ask" ask "$w"
done
# -c は他のオプション文字と束ねられる。c の後ろの文字を許さないと、-ce で素通しに戻る（ガードが開く方向の回帰）
for w in "bash -ce 'git add -A'" "bash -cex 'git add .'" "sh -ce 'git add -A'"; do
    t_expect "T-14 -c を束ねた wrapper（${w%% \'*}）は ask" ask "$w"
done
t_expect "T-15 wrapper の中の git -C <path> add は ask" ask "bash -lc 'git -C /r add tmp/x'"
t_expect "T-15 bash --login -c は ask" ask "bash --login -c 'git add foo'"
# 外側の境界: ssh -c（暗号の指定）・flash -c を wrapper と取り違えない
t_expect "T-16 ssh -c は wrapper ではない（素通し）" pass 'ssh -c aes128-ctr host git add .'
t_expect "T-16 flash -c は wrapper ではない（素通し）" pass "flash -c 'git add foo'"
t_expect "T-17 git -C <path> reset --hard は ask" ask 'git -C /repo reset --hard' "$CONFIRM_HOOK"
t_expect "T-17 git -C <path> push --force は ask" ask 'git -C /r push --force' "$CONFIRM_HOOK"
t_expect "T-18 wrapper の外の直接の git add -A は deny（wrapper の ask に弱めない）" deny "bash -c 'echo hi' && git add -A"
t_expect "T-19 2 つ目以降の git add の tmp/ も deny する" deny 'git add src/a.ts && git add tmp/x'
# :!tmp/ の除外は git add の出現ごと（行単位）。コマンド全体で 1 回見ると、どこかの :!tmp/ で全部の判定が止まる
t_expect "T-20 :!tmp/ の除外は、別の git add の tmp/ を素通しさせない" deny "git add src ':!tmp/' && git add tmp/c"
# T-21: 破壊的 git の行の後ろに約 64 KB 超が続くと、パイプの grep -q が SIGPIPE で落ちて素通しする（位置を問わない）
t_expect "T-21 先頭行の git reset --hard の後ろに 120 KB が続いても ask" ask \
    "$(printf 'git reset --hard\n%s' "$t_pad")" "$CONFIRM_HOOK"
t_expect "T-21 2 行目の git reset --hard の後ろに 120 KB が続いても ask" ask \
    "$(printf 'echo hi\ngit reset --hard\n%s' "$t_pad")" "$CONFIRM_HOOK"

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

LINK_SH="$REPO_ROOT/shared/scripts/link-contract.sh"
UNLINK_SH="$REPO_ROOT/shared/scripts/unlink-contract.sh"

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

# =====================================================================
# find-orphan-collections.mjs の挙動テスト（W-1〜W-16）
# =====================================================================
# 孤児判定が黙って開くと、生きている collection を drop する事故になる（非可逆）。
# Milvus は node のスタブで置き換える。スタブは 1 回だけ起動し、要求ごとに fixture JSON を
# 読み直すので、ケースの切り替えは fixture の書き換えで行う（起動待ちと後始末を 1 回に抑える）

# collection 名のハッシュは実装と同じ式で算出する。ハードコードすると $WORK の
# /var と /private/var の差で壊れるため、パスは pwd -P で実体化してから渡す
md5_8() {
    node -e 'const c=require("node:crypto"),p=require("node:path");process.stdout.write(c.createHash("md5").update(p.resolve(process.argv[1])).digest("hex").slice(0,8))' "$1"
}

w="$(cd "$WORK" && pwd -P)/orphan"
mkdir -p "$w/live-dir" "$w/live-snap" "$w/home"

cat > "$w/milvus-stub.mjs" <<'EOF'
import { createServer } from 'node:http';
import { appendFileSync, readFileSync, renameSync, writeFileSync } from 'node:fs';

const [fixturePath, dropLog, portFile] = process.argv.slice(2);

const server = createServer((req, res) => {
  let body = '';
  req.on('data', (chunk) => { body += chunk; });
  req.on('end', () => {
    const fx = JSON.parse(readFileSync(fixturePath, 'utf8'));
    const name = body ? JSON.parse(body).collectionName : undefined;
    const col = fx.collections[name];
    const op = req.url.replace(/^\/v2\/vectordb\/collections\//, '');
    let out;
    if (op === 'list') {
      out = fx.listCode === 0
        ? { code: 0, data: Object.keys(fx.collections) }
        : { code: fx.listCode, message: 'stub list error' };
    } else if (op === 'drop') {
      appendFileSync(dropLog, `${name}\n`);
      out = { code: 0, data: {} };
    } else if (!col) {
      out = { code: 100, message: 'collection not found' };
    } else if (op === 'describe' && col.hangup) {
      // list の後に Milvus が落ちた状況の再現
      req.socket.destroy();
      return;
    } else if (op === 'describe') {
      out = col.describeCode
        ? { code: col.describeCode, message: 'stub describe error' }
        : { code: 0, data: { collectionName: name, description: col.description } };
    } else if (op === 'get_stats') {
      out = { code: 0, data: { rowCount: col.rowCount } };
    } else {
      out = { code: 404, message: `unknown op: ${op}` };
    }
    // 実 Milvus と同じく、エラーも HTTP 200 のまま body の code で返す
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(out));
  });
});

server.listen(0, '127.0.0.1', () => {
  writeFileSync(`${portFile}.tmp`, String(server.address().port));
  renameSync(`${portFile}.tmp`, portFile);
});
EOF

W_FIXTURE="$w/fixture.json"
W_DROPS="$w/drops.log"
W_SNAPSHOT="$w/snapshot.json"

w_n1="hybrid_code_chunks_$(md5_8 "$w/gone-dir")"      # description あり・元パス無し → orphan
w_n2="code_chunks_$(md5_8 "$w/live-dir")"             # description あり・元パス有り → live
w_n3="hybrid_code_chunks_$(md5_8 "$w/live-snap")"     # description 無し・snapshot で live
w_n4="hybrid_code_chunks_$(md5_8 "$w/gone-snap")"     # description 無し・snapshot で orphan
w_n5="hybrid_code_chunks_$(md5_8 "$w/gone-nosnap")"   # description 無し・snapshot にも無い
w_n6="hybrid_code_chunks_$(md5_8 "$w/describe-fail")" # describe が code≠0
w_n7="hybrid_code_chunks_$(md5_8 "$w/other-path")"    # description の元パスとハッシュが不一致
w_n8="some_other_collection"                          # 対象外の接頭辞

write_w_fixture() {  # $1=list の code
    jq -n --argjson lc "$1" \
        --arg n1 "$w_n1" --arg n2 "$w_n2" --arg n3 "$w_n3" --arg n4 "$w_n4" \
        --arg n5 "$w_n5" --arg n6 "$w_n6" --arg n7 "$w_n7" --arg n8 "$w_n8" \
        --arg w "$w" '{
            listCode: $lc,
            collections: {
                ($n1): {description: ("codebasePath:" + $w + "/gone-dir"), rowCount: 12},
                ($n2): {description: ("codebasePath:" + $w + "/live-dir"), rowCount: 5},
                ($n3): {description: "", rowCount: 7},
                ($n4): {description: "", rowCount: 9},
                ($n5): {description: "", rowCount: 3},
                ($n6): {describeCode: 1100, rowCount: 1},
                ($n7): {description: ("codebasePath:" + $w + "/gone-dir7"), rowCount: 4},
                ($n8): {description: ("codebasePath:" + $w + "/gone-dir"), rowCount: 2}
            }
        }' > "$W_FIXTURE"
}
write_w_fixture 0

jq -n --arg w "$w" '{
    formatVersion: "v2",
    codebases: {
        ($w + "/live-snap"): {status: "indexed"},
        ($w + "/gone-snap"): {status: "indexed"}
    }
}' > "$W_SNAPSHOT"

node "$w/milvus-stub.mjs" "$W_FIXTURE" "$W_DROPS" "$w/port" >/dev/null 2>&1 &
STUB_PID=$!
# job から外す。外さないと trap での kill 時に「Terminated: 15」がテスト出力へ混ざる
disown "$STUB_PID"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -s "$w/port" ]] && break
    sleep 0.2
done
if [[ -s "$w/port" ]]; then
    W_STUB="127.0.0.1:$(cat "$w/port")"
else
    fail "W-0 Milvus スタブが 2 秒以内に起動しない（以降の W ケースは接続できずに FAIL する）"
    W_STUB="127.0.0.1:1"
fi
# 何も listen していないポート。1 番は特権ポートで、通常の環境では接続拒否になる
W_CLOSED="127.0.0.1:1"

# node の実体は HOME を差し替える前に解決しておく。mise 等のバージョン管理の shim は
# HOME 配下の設定を読むため、差し替えた HOME で起動すると node 自体が立ち上がらない
NODE_BIN="$(node -e 'process.stdout.write(process.execPath)')"

# 利用者の実設定（~/.claude.json・~/.context/.env・シェルの MILVUS_*）を読ませない。
# stdout だけを JSON として返し、stderr は捨てずにファイルへ残す（失敗時の手がかり）
run_orphan() {  # $1=HOME, $2=MILVUS_ADDRESS（空なら未設定）, 以降 script の引数
    local home="$1" addr="$2"; shift 2
    if [[ -n "$addr" ]]; then
        env -u MILVUS_TOKEN HOME="$home" MILVUS_ADDRESS="$addr" "$NODE_BIN" "$ORPHAN" "$@" 2>"$w/stderr"
    else
        env -u MILVUS_TOKEN -u MILVUS_ADDRESS HOME="$home" "$NODE_BIN" "$ORPHAN" "$@" 2>"$w/stderr"
    fi
    echo "$?" > "$RC_FILE"
}

# 終了コードと JSON の形を先に固定する。否定形の期待（「orphans に入らない」等）は、
# script が存在せず何も出力しなくても成立してしまうため、前提が崩れたら中身を見ずに FAIL にする
w_check_rc() {  # $1=期待する exit code。一致しなければ理由を出して 1 を返す
    local rc
    rc=$(cat "$RC_FILE" 2>/dev/null || echo "?")
    if [[ "$rc" == "$1" ]]; then
        return 0
    fi
    echo "       exit code: 期待 $1 / 実際 ${rc}（stderr: $(head -c 300 "$w/stderr" 2>/dev/null)）" >&2
    return 1
}

assert_orphan() {  # $1=ラベル, $2=stdout, $3=期待する exit code, $4=必須のトップレベルキー, $5=jq 式, 以降 jq の引数
    local label="$1" out="$2" rc="$3" key="$4" expr="$5"; shift 5
    if ! w_check_rc "$rc"; then
        fail "$label"; return
    fi
    if ! jq -e --arg k "$key" 'has($k)' <<<"$out" >/dev/null 2>&1; then
        fail "$label"
        echo "       stdout が JSON でないか、キー $key が無い: ${out:-（出力なし）}" >&2
        return
    fi
    if jq -e "$@" "$expr" <<<"$out" >/dev/null 2>&1; then
        pass "$label"
    else
        fail "$label"
        echo "       条件 $expr を満たさない: $out" >&2
    fi
}

# 異常終了時は stdout に orphans を出さない（「孤児 0 件」と区別できなくなるため）。
# exit 1 は node 自体のクラッシュ（script 不在の Cannot find module 等）とも一致するので、
# その場合は stderr に原因が出ていることまで見ないと偽陽性になる
assert_orphan_aborted() {  # $1=ラベル, $2=stdout, $3=期待する exit code, $4=stderr に期待する部分文字列（省略可）
    if ! w_check_rc "$3"; then
        fail "$1"; return
    fi
    if [[ "$2" == *'"orphans"'* ]]; then
        fail "$1"
        echo "       異常終了なのに stdout に orphans がある: $2" >&2
    elif [[ -n "${4:-}" ]] && [[ "$(cat "$w/stderr" 2>/dev/null)" != *"$4"* ]]; then
        fail "$1"
        echo "       stderr に「$4」が無い: $(head -c 300 "$w/stderr" 2>/dev/null)" >&2
    else
        pass "$1"
    fi
}

in_orphans='any(.orphans[]; .name == $n)'
in_unknown='any(.unknown[]; .name == $n)'

# --- W-1〜W-8: list モードの分類 ---
w_out="$(run_orphan "$w/home" "$W_STUB" --snapshot "$W_SNAPSHOT")"
assert_orphan "W-1 元パスが無い collection は orphans に入り、行数が付く" \
    "$w_out" 0 orphans "any(.orphans[]; .name == \$n and .rowCount == 12 and .pathSource == \"description\")" --arg n "$w_n1"
assert_orphan "W-2 元パスが有る collection は orphans にも unknown にも入らず live に数える" \
    "$w_out" 0 orphans "($in_orphans or $in_unknown | not) and .liveCount == 2" --arg n "$w_n2"
assert_orphan "W-3 description が無くても snapshot で元パスが有れば live" \
    "$w_out" 0 orphans "($in_orphans or $in_unknown) | not" --arg n "$w_n3"
assert_orphan "W-4 description が無く snapshot の元パスが無ければ orphans（pathSource: snapshot）" \
    "$w_out" 0 orphans "any(.orphans[]; .name == \$n and .pathSource == \"snapshot\")" --arg n "$w_n4"
assert_orphan "W-5 元パスが特定できない collection は unknown に倒す（orphans に入れない）" \
    "$w_out" 0 orphans "$in_unknown and ($in_orphans | not)" --arg n "$w_n5"
assert_orphan "W-6 describe が code≠0 なら unknown に倒す" \
    "$w_out" 0 orphans "$in_unknown and ($in_orphans | not)" --arg n "$w_n6"
assert_orphan "W-7 description の元パスと名前のハッシュが一致しなければ unknown" \
    "$w_out" 0 orphans "$in_unknown and ($in_orphans | not)" --arg n "$w_n7"
assert_orphan "W-8 対象外の接頭辞の collection はどの配列にも現れない" \
    "$w_out" 0 orphans "($in_orphans or $in_unknown) | not" --arg n "$w_n8"

# --- W-9: snapshot が無くても live を orphan と誤判定しない ---
w9_out="$(run_orphan "$w/home" "$W_STUB" --snapshot "$w/no-such-snapshot.json")"
assert_orphan "W-9a snapshot 不在でも description で判定できるものは orphans のまま" \
    "$w9_out" 0 orphans "$in_orphans" --arg n "$w_n1"
assert_orphan "W-9b snapshot 不在で元パスが特定できない live は unknown に落ちる（orphans に入れない）" \
    "$w9_out" 0 orphans "$in_unknown and ($in_orphans | not)" --arg n "$w_n3"

# --- W-17: 元パスの実在を確認できない（権限エラー）ものは unknown に倒す ---
# macOS の TCC 保護下（~/Documents 等）では、生きているディレクトリでも stat が EPERM を返す。
# ENOENT 以外のエラーを「存在しない」と扱うと live を orphan と誤判定する。
# root では権限が効かず fixture が成立しないため skip する
if [[ "$(id -u)" == "0" ]]; then
    echo "[SKIP] W-17 root では権限エラーを再現できない"
else
    w_n9="hybrid_code_chunks_$(md5_8 "$w/locked/inner")"
    mkdir -p "$w/locked/inner"
    cp "$W_FIXTURE" "$w/fixture.bak"
    jq --arg n "$w_n9" --arg p "codebasePath:$w/locked/inner" \
        '.collections[$n] = {description: $p, rowCount: 1}' "$w/fixture.bak" > "$W_FIXTURE"
    chmod 000 "$w/locked"
    w17_out="$(run_orphan "$w/home" "$W_STUB" --snapshot "$W_SNAPSHOT")"
    chmod 755 "$w/locked"
    mv "$w/fixture.bak" "$W_FIXTURE"
    assert_orphan "W-17 元パスの stat が権限エラーなら unknown に倒す（orphans に入れない）" \
        "$w17_out" 0 orphans "$in_unknown and ($in_orphans | not)" --arg n "$w_n9"
fi

# --- W-10: Milvus に到達できないときは「0 件」と区別できる形で止まる ---
assert_orphan_aborted "W-10 Milvus に到達できなければ exit 2 で orphans を出さない" \
    "$(run_orphan "$w/home" "$W_CLOSED" --snapshot "$W_SNAPSHOT")" 2

# list の後で到達できなくなった場合も同じ。describe の失敗を unknown に紛れさせると、
# 全件が unknown の「孤児 0 件」として報告される
cp "$W_FIXTURE" "$w/fixture.bak"
jq --arg n "$w_n1" '.collections[$n].hangup = true' "$w/fixture.bak" > "$W_FIXTURE"
assert_orphan_aborted "W-10b list の後に Milvus が応答しなくなっても exit 2 で orphans を出さない" \
    "$(run_orphan "$w/home" "$W_STUB" --snapshot "$W_SNAPSHOT")" 2
mv "$w/fixture.bak" "$W_FIXTURE"

# --- W-11 / W-12: drop モードは drop 直前に再判定する ---
rm -f "$W_DROPS"
w11_out="$(run_orphan "$w/home" "$W_STUB" --snapshot "$W_SNAPSHOT" --drop "$w_n2")"
assert_orphan "W-11a live の collection の drop は refused になる" \
    "$w11_out" 1 results "any(.results[]; .name == \$n and .status == \"refused\")" --arg n "$w_n2"
w11_label="W-11b refused のときスタブへ drop 要求を送らない"
if w_check_rc 1 && [[ "$w11_out" == *'"results"'* ]] && [[ ! -s "$W_DROPS" ]]; then
    pass "$w11_label"
else
    fail "$w11_label"
    echo "       drop 記録: $(cat "$W_DROPS" 2>/dev/null || echo '（なし）')" >&2
fi

rm -f "$W_DROPS"
w12_out="$(run_orphan "$w/home" "$W_STUB" --snapshot "$W_SNAPSHOT" --drop "$w_n1")"
assert_orphan "W-12a 孤児の collection の drop は dropped になる" \
    "$w12_out" 0 results "any(.results[]; .name == \$n and .status == \"dropped\")" --arg n "$w_n1"
w12_label="W-12b スタブへの drop 要求は承認した 1 件だけ"
if w_check_rc 0 && [[ "$(cat "$W_DROPS" 2>/dev/null)" == "$w_n1" ]]; then
    pass "$w12_label"
else
    fail "$w12_label"
    echo "       drop 記録: $(cat "$W_DROPS" 2>/dev/null || echo '（なし）')" >&2
fi

# --- W-13: list が code≠0 なら「0 件」と報告しない ---
write_w_fixture 1
assert_orphan_aborted "W-13 list が code≠0 なら exit 1 で orphans を出さず、Milvus のエラー本文を stderr に出す" \
    "$(run_orphan "$w/home" "$W_STUB" --snapshot "$W_SNAPSHOT")" 1 "stub list error"
write_w_fixture 0

# --- W-14〜W-16: 接続設定は MCP と同じ解決順で決める ---
# MCP の設定は ~/.claude.json にあり、シェルには無い。シェルの環境変数を優先すると、
# MCP とは別の Milvus を点検して「孤児 0 件」と報告しうる
mkdir -p "$w/home14" "$w/home15" "$w/home16/.context"
jq -n --arg a "$W_STUB" '{mcpServers: {"claude-context": {env: {MILVUS_ADDRESS: $a}}}}' > "$w/home14/.claude.json"
assert_orphan "W-14 ~/.claude.json の MCP env をシェルの環境変数より優先する" \
    "$(run_orphan "$w/home14" "$W_CLOSED" --snapshot "$W_SNAPSHOT")" 0 orphans '.milvusSource == "claude.json"'

jq -n '{mcpServers: {"claude-context": {env: {MILVUS_ADDRESS: ""}}}}' > "$w/home15/.claude.json"
assert_orphan "W-15 ~/.claude.json の空文字は未設定として扱い、環境変数へ進む" \
    "$(run_orphan "$w/home15" "$W_STUB" --snapshot "$W_SNAPSHOT")" 0 orphans '.milvusSource == "env"'

printf 'MILVUS_ADDRESS=%s\n' "$W_STUB" > "$w/home16/.context/.env"
assert_orphan "W-16 ~/.claude.json も環境変数も無ければ ~/.context/.env を使う" \
    "$(run_orphan "$w/home16" "" --snapshot "$W_SNAPSHOT")" 0 orphans '.milvusSource == "dotenv"'

# =====================================================================
# GD / CX: ask を返す hook 4 本の Claude 側の出力（ゴールデン）と、Codex 側の ask → deny 変換
# =====================================================================
# Codex は permissionDecision: "ask"（確認プロンプト）に未対応で、未対応の値は hook の失敗として
# 扱われ操作が続行する（ガードが黙って開く）。Codex の PreToolUse 入力は turn_id を持つ
# （Claude Code の入力には無い）ので、それで見分けて ask を deny に変える。
# 変換のために hook を触っても、turn_id の無い Claude Code の出力は 1 バイトも変えてはいけない。
# ゴールデンは変換を入れる前の出力を固定したもの。作り直す（UPDATE_GOLDEN=1）のは、契約を
# 意図して変えたときだけにする（作り直せば何でも通るので、回帰の検出力はここで決まる）
# GD-6・GD-7 の理由文には skill の配置パス（shared/skills/_template/…）が入る。配置を移したら
# ゴールデンも作り直す（契約の意図した変更にあたる）
GOLDEN_DIR="$SCRIPT_DIR/golden"
LINT_HOOK="$REPO_ROOT/shared/scripts/hook-lint-skill-frontmatter.sh"

# 一時ディレクトリのパスは実行ごとに変わる（macOS では /var と /private/var の 2 表記がある）
golden_normalize() {
    local real
    real="$(cd "$WORK" && pwd -P)"
    sed -e "s|$real|<TMP>|g" -e "s|$WORK|<TMP>|g"
}

# hook を起動し、「rc=<終了コード>」の行に続けて標準出力と標準エラーをそのまま $WORK/golden.actual に書く。
# $(...) を挟まないのは、末尾の改行を落とさず、バイト単位で比べるため
golden_capture() {  # $1=hook, $2=入力 JSON
    printf '%s' "$2" | bash "$1" >"$WORK/golden.raw" 2>&1
    local rc=$?
    { echo "rc=${rc}"; cat "$WORK/golden.raw"; } | golden_normalize >"$WORK/golden.actual"
}

assert_golden() {  # $1=ラベル, $2=ゴールデンの名前, $3=hook, $4=入力 JSON
    golden_capture "$3" "$4"
    local file="$GOLDEN_DIR/$2.golden"
    if [[ "${UPDATE_GOLDEN:-0}" == 1 ]]; then
        mkdir -p "$GOLDEN_DIR"
        cp "$WORK/golden.actual" "$file"
        pass "$1（ゴールデンを更新した）"
    elif [[ ! -f "$file" ]]; then
        fail "$1（ゴールデンが無い: ${file}）"
    elif cmp -s "$file" "$WORK/golden.actual"; then
        pass "$1"
    else
        fail "$1"
        diff -u "$file" "$WORK/golden.actual" | sed 's/^/       /' >&2
    fi
}

assert_equal() {  # $1=ラベル, $2=期待値, $3=実際の値
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1"
        echo "       期待: ${2:-（空）}" >&2
        echo "       実際: ${3:-（空）}" >&2
    fi
}

# 値は jq で取り出して比べる。出力全体への部分文字列照合は、元の理由文に含まれる語への偶然マッチを拾う
decision_of() { jq -r '.hookSpecificOutput.permissionDecision // "（なし）"' <<<"$1"; }
reason_of() { jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<<"$1"; }

# ask を出す入力で、turn_id なしなら ask、足すと deny（理由に [要確認] と元の理由）になること
assert_ask_becomes_deny() {  # $1=ラベル, $2=hook, $3=Claude 入力の JSON, $4=元の理由に含まれる語
    local claude_json="$3" codex_json out rc
    codex_json="$(jq -c '. + {turn_id: "t-test"}' <<<"$claude_json")"
    out="$(printf '%s' "$claude_json" | bash "$2" 2>/dev/null)"
    # 前提。最初から deny を返す入力だと、変換を何も検査していないのに通る
    assert_equal "$1 [前提] turn_id なしでは ask" "ask" "$(decision_of "$out")"
    out="$(printf '%s' "$codex_json" | bash "$2" 2>/dev/null)"
    rc=$?
    assert_equal "$1 [Codex] turn_id ありでは deny" "deny" "$(decision_of "$out")"
    assert_contains "$1 [Codex] 理由に [要確認] を付ける" "$(reason_of "$out")" "[要確認]"
    assert_contains "$1 [Codex] 元の理由を残す" "$(reason_of "$out")" "$4"
    assert_equal "$1 [Codex] exit 0" "0" "$rc"
}

# --- 入力 ---
# Claude Code の実際の入力が持つキーを揃える。Codex の判定を turn_id 以外のキーに広げる回帰を検知するため
claude_payload() { jq -c '{session_id:"s-test",transcript_path:"/tmp/t.jsonl",cwd:"/",permission_mode:"default",
                           hook_event_name:"PreToolUse",tool_use_id:"toolu_test"} + .' <<<"$1"; }
GD_DESTRUCTIVE="$(claude_payload '{"tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD"},"cwd":"/"}')"
GD_PASS="$(claude_payload '{"tool_name":"Bash","tool_input":{"command":"git status"},"cwd":"/"}')"
GD_WRAPPER="$(claude_payload '{"tool_name":"Bash","tool_input":{"command":"bash -c \"git add foo\""},"cwd":"/"}')"
GD_ADD_ALL="$(claude_payload '{"tool_name":"Bash","tool_input":{"command":"git add -A"},"cwd":"/"}')"
GD_COMMIT="$(claude_payload "$(jq -nc --arg w "$f1/apps/web" '{tool_name:"Bash",tool_input:{command:"git commit -m x"},cwd:$w}')")"

lint_write() {  # $1=file_path, $2=content
    claude_payload "$(jq -nc --arg p "$1" --arg c "$2" '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}')"
}
LINT_NO_FM="$(lint_write /fx/skills/demo/SKILL.md $'no frontmatter here\n')"
LINT_NO_DESC="$(lint_write /fx/skills/demo/SKILL.md $'---\nname: demo\n---\nbody\n')"
LINT_NO_TRIGGER="$(lint_write /fx/skills/demo/SKILL.md $'---\nname: demo\ndescription: Does a thing.\n---\nbody\n')"
LINT_VALID="$(lint_write /fx/skills/demo/SKILL.md $'---\nname: demo\ndescription: Does a thing. 使用する時に呼ぶ。\n---\nbody\n')"
LINT_TEMPLATE="$(lint_write /fx/skills/_template/SKILL.md $'no frontmatter at all\n')"

# Edit / MultiEdit は現ファイルを読む。前処理の失敗は、Edit は読めないファイル、MultiEdit は
# edits に辞書でない要素を入れて起こす（後者のエラー文は決定的で、パスを含まない）
GD_LINT_DIR="$WORK/gd-lint"
mkdir -p "$GD_LINT_DIR/unreadable" "$GD_LINT_DIR/readable"
printf '%s\n' '---' 'name: demo' 'description: Does a thing. 使用する時に呼ぶ。' '---' 'body' >"$GD_LINT_DIR/unreadable/SKILL.md"
cp "$GD_LINT_DIR/unreadable/SKILL.md" "$GD_LINT_DIR/readable/SKILL.md"
chmod 000 "$GD_LINT_DIR/unreadable/SKILL.md"
LINT_EDIT_FAIL="$(claude_payload "$(jq -nc --arg p "$GD_LINT_DIR/unreadable/SKILL.md" '{tool_name:"Edit",tool_input:{file_path:$p,old_string:"body",new_string:"changed"}}')")"
LINT_MULTI_FAIL="$(claude_payload "$(jq -nc --arg p "$GD_LINT_DIR/readable/SKILL.md" '{tool_name:"MultiEdit",tool_input:{file_path:$p,edits:["not-a-dict"]}}')")"
LINT_EDIT_OK="$(claude_payload "$(jq -nc --arg p "$GD_LINT_DIR/readable/SKILL.md" '{tool_name:"Edit",tool_input:{file_path:$p,old_string:"body",new_string:"changed"}}')")"

# --- GD: turn_id なし（Claude Code）の出力と終了コードが、変換を入れる前と同一 ---
# 出力箇所ごとに 1 件（理由文まで固定する）。素通しの入力も含め、過剰検知（日常的に出る確認）も捕まえる
assert_golden "GD-1 confirm-destructive: git reset --hard は ask" confirm-destructive-git-reset-hard "$CONFIRM_HOOK" "$GD_DESTRUCTIVE"
assert_golden "GD-2 confirm-destructive: 破壊的でない git は素通し" confirm-destructive-git-pass "$CONFIRM_HOOK" "$GD_PASS"
assert_golden "GD-3 tmp-commit: git add を運ぶ wrapper は ask" block-tmp-commit-wrapper-ask "$TMP_HOOK" "$GD_WRAPPER"
assert_golden "GD-4 tmp-commit: git add -A は deny" block-tmp-commit-add-all-deny "$TMP_HOOK" "$GD_ADD_ALL"
assert_golden "GD-5 local-contract-link: staged な link: は ask" block-local-contract-link-package-json-ask "$HOOK" "$GD_COMMIT"
assert_golden "GD-6 lint: frontmatter 無しの Write は ask" lint-skill-frontmatter-write-no-frontmatter "$LINT_HOOK" "$LINT_NO_FM"
assert_golden "GD-7 lint: 必須フィールド欠落の Write は deny" lint-skill-frontmatter-write-missing-description "$LINT_HOOK" "$LINT_NO_DESC"
assert_golden "GD-8 lint: トリガー語の無い Write は ask" lint-skill-frontmatter-write-no-trigger "$LINT_HOOK" "$LINT_NO_TRIGGER"
assert_golden "GD-9 lint: 正しい Write は素通し" lint-skill-frontmatter-write-valid "$LINT_HOOK" "$LINT_VALID"
assert_golden "GD-10 lint: _template/SKILL.md は検査対象外で素通し" lint-skill-frontmatter-template-pass "$LINT_HOOK" "$LINT_TEMPLATE"
assert_golden "GD-11 lint: Edit の前処理失敗は ask（理由にパスを含む）" lint-skill-frontmatter-edit-prep-failed "$LINT_HOOK" "$LINT_EDIT_FAIL"
assert_golden "GD-12 lint: MultiEdit の前処理失敗は ask" lint-skill-frontmatter-multiedit-prep-failed "$LINT_HOOK" "$LINT_MULTI_FAIL"
assert_golden "GD-13 lint: 正しい Edit は素通し" lint-skill-frontmatter-edit-valid "$LINT_HOOK" "$LINT_EDIT_OK"

# --- CX: turn_id あり（Codex）では ask を deny にする。出力箇所ごとに 1 件 ---
assert_ask_becomes_deny "CX-1 confirm-destructive" "$CONFIRM_HOOK" "$GD_DESTRUCTIVE" "破壊的 git 操作を検出しました"
assert_ask_becomes_deny "CX-2 tmp-commit の wrapper" "$TMP_HOOK" "$GD_WRAPPER" "git add を含む wrapper コマンド"
assert_ask_becomes_deny "CX-3 local-contract-link" "$HOOK" "$GD_COMMIT" "link: / file:"
assert_ask_becomes_deny "CX-4 lint: frontmatter 無し" "$LINT_HOOK" "$LINT_NO_FM" "YAML frontmatter"
assert_ask_becomes_deny "CX-5 lint: トリガー語なし" "$LINT_HOOK" "$LINT_NO_TRIGGER" "トリガー語"
assert_ask_becomes_deny "CX-6 lint: Edit の前処理失敗" "$LINT_HOOK" "$LINT_EDIT_FAIL" "前処理に失敗しました"
assert_ask_becomes_deny "CX-7 lint: MultiEdit の前処理失敗" "$LINT_HOOK" "$LINT_MULTI_FAIL" "前処理に失敗しました"

# deny を返す箇所は Codex でも変えない（[要確認] は「確認すれば進める」を意味するので、確認で進めない deny に付けない）
out="$(printf '%s' "$(jq -c '. + {turn_id: "t-test"}' <<<"$GD_ADD_ALL")" | bash "$TMP_HOOK" 2>/dev/null)"
assert_equal "CX-8 tmp-commit の deny は Codex でも deny のまま" "deny" "$(decision_of "$out")"
assert_equal "CX-9 tmp-commit の deny の理由に [要確認] を付けない" "no" \
    "$([[ "$(reason_of "$out")" == *"[要確認]"* ]] && echo yes || echo no)"
out="$(printf '%s' "$(jq -c '. + {turn_id: "t-test"}' <<<"$LINT_NO_DESC")" | bash "$LINT_HOOK" 2>/dev/null)"
assert_equal "CX-10 lint の必須フィールド欠落は Codex でも deny のまま" "deny" "$(decision_of "$out")"

# 素通しは Codex でも素通し（ask でない入力を deny にしない）
out="$(printf '%s' "$(jq -c '. + {turn_id: "t-test"}' <<<'{"tool_input":{"command":"git status"},"cwd":"/"}')" | bash "$CONFIRM_HOOK" 2>/dev/null; echo "${PIPESTATUS[1]}" >"$RC_FILE")"
assert_hook_empty "CX-11 破壊的でない git は Codex でも素通し（出力が空で、exit 0）" "$out"

# --- CX-12・CX-13: Codex で lint が止めたときの次の行動は、用途に合わせる ---
# 既定の「ユーザー自身に実行してもらう」は、直せば済む frontmatter の欠落にまでユーザーを回す。
# 既定の文の後ろに新しい文を足しただけの形（食い違う指示が並ぶ）も Red にするため、既定の文が無いことも見る
codex_of() { jq -c '. + {turn_id: "t-test"}' <<<"$1"; }
out="$(printf '%s' "$(codex_of "$LINT_NO_FM")" | bash "$LINT_HOOK" 2>/dev/null)"
assert_contains "CX-12 frontmatter 無しの deny は、frontmatter を付けて編集し直すよう促す" "$(reason_of "$out")" "frontmatter を付けた内容で編集し直してください"
assert_not_contains "CX-12 frontmatter 無しの deny は、ユーザー自身に実行させない" "$(reason_of "$out")" "ユーザー自身に実行"
out="$(printf '%s' "$(codex_of "$LINT_NO_TRIGGER")" | bash "$LINT_HOOK" 2>/dev/null)"
assert_contains "CX-13 トリガー語なしの deny は、このままでよいかをユーザーに確認するよう促す" "$(reason_of "$out")" "このままでよいかユーザーに確認"
assert_not_contains "CX-13 トリガー語なしの deny は、ユーザー自身に実行させない" "$(reason_of "$out")" "ユーザー自身に実行"

# --- CX-14: trace（CLAUDE_CODE_HOOK_TRACE）に実際の判定を記録する（Codex では deny）---
TRH="$WORK/trace-home"
mkdir -p "$TRH"
printf '%s' "$(codex_of "$GD_DESTRUCTIVE")" | HOME="$TRH" CLAUDE_CODE_HOOK_TRACE=1 bash "$CONFIRM_HOOK" >/dev/null 2>&1
printf '%s' "$(codex_of "$LINT_NO_TRIGGER")" | HOME="$TRH" CLAUDE_CODE_HOOK_TRACE=1 bash "$LINT_HOOK" >/dev/null 2>&1
printf '%s' "$(codex_of "$GD_COMMIT")" | HOME="$TRH" CLAUDE_CODE_HOOK_TRACE=1 bash "$HOOK" >/dev/null 2>&1
trace_log="$(cat "$TRH/.claude/logs/hook-trace.log" 2>/dev/null)"
assert_contains "CX-14 破壊的 git の trace に Codex での判定（deny）を記録する" "$trace_log" "hook-confirm-destructive-git.sh matched=true decision=deny"
assert_contains "CX-14 lint の trace に Codex での判定（deny）を記録する" "$trace_log" "decision=deny reason=trigger-missing"
assert_contains "CX-14 contract-link の trace に Codex での判定（deny）を記録する" "$trace_log" "decision=deny reason=local-link-package-json"

# --- IN-1・IN-2: オブジェクトでない JSON の入力（PreToolUse の 5 本）---
# jq -e . は配列や {"tool_input":false} を通し、後続の jq が exit 5 で落ちる（exit 2 以外は non-blocking なので素通し）。
# Claude Code・Codex の正常な入力は常にオブジェクトなので、{} と tool_input: null は従来どおり通す
for h in "$TMP_HOOK" "$CONFIRM_HOOK" "$LINT_HOOK" "$REPO_ROOT/shared/scripts/hook-block-full-lint.sh" "$HOOK"; do
    for inp in '[]' '{"tool_input":false}'; do
        printf '%s' "$inp" | bash "$h" >/dev/null 2>&1
        rc=$?  # 引数の $(basename …) が先に展開されて $? を上書きするので、すぐに取る
        assert_equal "IN-1 [$(basename "$h")] ${inp} は exit 2 で止める（素通しにしない）" "2" "$rc"
    done
    for inp in '{}' '{"tool_input":null}'; do
        printf '%s' "$inp" | bash "$h" >/dev/null 2>&1
        rc=$?
        assert_equal "IN-2 [$(basename "$h")] ${inp} は従来どおり exit 0" "0" "$rc"
    done
done

# =====================================================================
# AP: apply_patch で書かれる SKILL.md の lint（Codex）
# =====================================================================
# Codex は SKILL.md の編集を Write / Edit ではなく apply_patch で行う。apply_patch の入力には
# tool_input.file_path が無く（patch 本文は tool_input.command）、既存の早期 return
# （FILE_PATH が /SKILL.md で終わらなければ素通し）で必ず素通りする。Codex 側の lint は
# 黙って開いた状態だった
#
# patch の書式は、Codex 0.160.0 のバイナリに同梱された apply_patch の文法（Lark）に従う:
#   *** Begin Patch / [*** Environment ID: <id>] / hunk+ / *** End Patch
#   hunk = Add File（+ 行）/ Delete File / Update File [*** Move to:] （@@ と ' ' '-' '+' の行、
#          先頭の hunk だけ @@ を省略できる）[*** End of File]
# 実機の hook 入力そのものは手元に無い（Codex を起動して取る手順はユーザー環境に触れるため行っていない）。
# 実機との照合は、Codex を起動して SKILL.md の name 行を消す patch を当てさせて行う
AP="$WORK/ap"
mkdir -p "$AP/skills/demo" "$AP/skills/second" "$AP/skills/_template"
cat >"$AP/skills/demo/SKILL.md" <<'EOF'
---
name: demo
description: Does a thing. 使用する時に呼ぶ。
---
# Demo

Line A
Line B
EOF
cp "$AP/skills/demo/SKILL.md" "$AP/skills/second/SKILL.md"
# 複数 hunk のケース用。frontmatter に tags 行があり、1 つ目の hunk で直したあと、2 つ目の hunk が description を消す
mkdir -p "$AP/skills/multi"
cat >"$AP/skills/multi/SKILL.md" <<'EOF'
---
name: multi
tags: a
description: Does a thing. 使用する時に呼ぶ。
---
body
EOF
printf '%s\n' 'plain text' >"$AP/README-old.md"
# 不正な内容の SKILL.md。Delete File の対象にして、消す前の内容を lint しないことを見る
mkdir -p "$AP/skills/broken"
printf '%s\n' 'no frontmatter here' >"$AP/skills/broken/SKILL.md"

# $1=patch 本文, $2=cwd（空なら入力に cwd を入れない）, $3=turn_id を付けるか（1 = Codex / 0 = 付けない）
lint_patch() {
    jq -nc --arg p "$1" --arg c "${2-}" --argjson t "${3:-1}" '
        {tool_name: "apply_patch", tool_input: {command: $p}}
        + (if $c != "" then {cwd: $c} else {} end)
        + (if $t == 1 then {turn_id: "t-test"} else {} end)'
}
run_ap() {  # $1=patch, $2=cwd, $3=turn_id（既定 1）→ hook の出力。終了コードは RC_FILE
    printf '%s' "$(lint_patch "$1" "$2" "${3:-1}")" | bash "$LINT_HOOK" 2>/dev/null
    echo "${PIPESTATUS[1]}" >"$RC_FILE"
}
# 素通しを「出力が空」だけで見ると、exit 2 へのハードブロック化や無出力のクラッシュも素通しに見える
# （上の assert_hook_rc の説明と同じ理由）。素通しも deny も、終了コードが 0 であることを固定する
assert_ap() {  # $1=ラベル, $2=期待する decision（空 = 素通し）, $3=出力, $4=理由に含まれるべき語（任意）
    if [[ -z "$2" ]]; then
        assert_hook_empty "$1" "$3"
    else
        assert_equal "$1 [decision]" "$2" "$(decision_of "$3")"
        [[ -z "${4-}" ]] || assert_contains "$1 [理由]" "$(reason_of "$3")" "$4"
        if assert_hook_rc "$1"; then pass "$1 [exit 0]"; else fail "$1 [exit 0]"; fi
    fi
}

PATCH_NAME_REMOVED="$(cat <<'EOF'
*** Begin Patch
*** Update File: skills/demo/SKILL.md
@@
 ---
-name: demo
 description: Does a thing. 使用する時に呼ぶ。
 ---
*** End Patch
EOF
)"

# AP-1 〜 AP-8: 基本の 8 ケース（Add / Update の正否・混在・複数ファイル・前処理の失敗・hook プロセスの cwd）
out="$(run_ap "$(cat <<'EOF'
*** Begin Patch
*** Add File: skills/x/SKILL.md
+---
+name: x
+---
+body
*** End Patch
EOF
)" "$AP")"
assert_ap "AP-1 Add File で description が無い SKILL.md は止める" deny "$out" "必須フィールド"
assert_contains "AP-1b 理由に対象ファイルのパスを含める（複数ファイルの patch で何が悪いか分かる）" "$(reason_of "$out")" "skills/x/SKILL.md"

out="$(run_ap "$(cat <<'EOF'
*** Begin Patch
*** Add File: skills/y/SKILL.md
+---
+name: y
+description: Does a thing. 使用する時に呼ぶ。
+---
+body
*** End Patch
EOF
)" "$AP")"
assert_ap "AP-2 Add File で正しい frontmatter の SKILL.md は素通し" "" "$out"

assert_ap "AP-3 Update File で name 行を消す hunk は止める" deny "$(run_ap "$PATCH_NAME_REMOVED" "$AP")" "必須フィールド"

out="$(run_ap "$(cat <<'EOF'
*** Begin Patch
*** Update File: skills/demo/SKILL.md
@@
 Line A
-Line B
+Line B changed
*** End Patch
EOF
)" "$AP")"
assert_ap "AP-4 Update File で本文だけを変える hunk は素通し" "" "$out"

out="$(run_ap "$(cat <<'EOF'
*** Begin Patch
*** Add File: docs/notes.md
+just notes
*** Update File: skills/demo/SKILL.md
@@
 ---
-name: demo
 description: Does a thing. 使用する時に呼ぶ。
 ---
*** End Patch
EOF
)" "$AP")"
assert_ap "AP-5 SKILL.md 以外と混在する patch でも SKILL.md 側が不正なら止める" deny "$out" "必須フィールド"

out="$(run_ap "$(cat <<'EOF'
*** Begin Patch
*** Update File: skills/demo/SKILL.md
@@
 this line does not exist in the file
-neither does this one
+replacement
*** End Patch
EOF
)" "$AP")"
assert_ap "AP-6 hunk の旧テキストが現ファイルに無い（前処理の失敗）は Codex では deny（fail-closed）" deny "$out" "前処理に失敗しました"
assert_equal "AP-6b 同じ入力を turn_id なしで入れると ask（Codex 以外は従来どおり確認に委ねる）" "ask" \
    "$(decision_of "$(run_ap "$(cat <<'EOF'
*** Begin Patch
*** Update File: skills/demo/SKILL.md
@@
 this line does not exist in the file
-neither does this one
+replacement
*** End Patch
EOF
)" "$AP" 0)")"

# 1 つの patch に SKILL.md が 2 件あり、2 件目だけが不正。1 件目だけを lint して終わる実装を捕まえる
out="$(run_ap "$(cat <<'EOF'
*** Begin Patch
*** Update File: skills/demo/SKILL.md
@@
 Line A
-Line B
+Line B changed
*** Update File: skills/second/SKILL.md
@@
 ---
-name: demo
 description: Does a thing. 使用する時に呼ぶ。
 ---
*** End Patch
EOF
)" "$AP")"
assert_ap "AP-7 SKILL.md が 2 件あり 2 件目だけが不正でも止める" deny "$out" "skills/second/SKILL.md"

# hook プロセスの cwd を fixture と別の場所にする。パスを入力の .cwd で解決していれば AP-3 と同じ結果になる
out="$(cd / && printf '%s' "$(lint_patch "$PATCH_NAME_REMOVED" "$AP")" | bash "$LINT_HOOK" 2>/dev/null; echo "${PIPESTATUS[1]}" >"$RC_FILE")"
assert_ap "AP-8 hook プロセスの cwd が別でも、パスは入力の .cwd で解決する" deny "$out" "必須フィールド"

# AP-9 〜 AP-12: 対象の判定（過剰検知と取りこぼしの両方）
out="$(run_ap "$(cat <<'EOF'
*** Begin Patch
*** Add File: skills/_template/SKILL.md
+no frontmatter at all
*** End Patch
EOF
)" "$AP")"
assert_ap "AP-9 _template/SKILL.md は検査対象外で素通し（雛形の編集を止めない）" "" "$out"

out="$(run_ap "$(cat <<'EOF'
*** Begin Patch
*** Update File: README-old.md
@@
-plain text
+changed text
*** End Patch
EOF
)" "$AP")"
assert_ap "AP-10 SKILL.md を含まない patch は素通し（前処理で止めない）" "" "$out"

out="$(run_ap "$(cat <<'EOF'
*** Begin Patch
*** Delete File: skills/broken/SKILL.md
*** End Patch
EOF
)" "$AP")"
assert_ap "AP-11 Delete File は、消す前の内容が不正でも素通し（消える物を lint して止めない）" "" "$out"

# 移動先のパスで判定する。移動元が SKILL.md でなくても、移動先が SKILL.md なら内容を検査する
out="$(run_ap "$(cat <<'EOF'
*** Begin Patch
*** Update File: README-old.md
*** Move to: skills/moved/SKILL.md
@@
-plain text
+still no frontmatter
*** End Patch
EOF
)" "$AP")"
assert_ap "AP-12 Move to で SKILL.md になる場合は移動先で判定する" deny "$out" "YAML frontmatter"

# AP-13 〜 AP-17: 文法から導いた書式の揺れ
out="$(run_ap "$(cat <<'EOF'
*** Begin Patch
*** Update File: skills/demo/SKILL.md
 ---
-name: demo
 description: Does a thing. 使用する時に呼ぶ。
 ---
*** End Patch
EOF
)" "$AP")"
assert_ap "AP-13 先頭の hunk は @@ を省略できる（文法どおり）。省略しても name 行の削除を見落とさない" deny "$out" "必須フィールド"

out="$(run_ap "$(cat <<'EOF'
*** Begin Patch
*** Update File: skills/demo/SKILL.md
@@
-Line B
+Line B at the end
*** End of File
*** End Patch
EOF
)" "$AP")"
assert_ap "AP-14 *** End of File 付きの hunk を適用でき、正しければ素通し" "" "$out"

# AP-14b・14c: *** End of File のアンカーは、hunk をファイルの末尾に当てる。末尾に --- があるファイルで、
# アンカーを無視して先頭から探すと frontmatter の開きの --- を消したと解釈して止めてしまう（実パーサは末尾を消す）
mkdir -p "$AP/skills/eof"
printf '%s\n' '---' 'name: eof' 'description: Does a thing. 使用する時に呼ぶ。' '---' '# Eof' '' 'Line A' '---' >"$AP/skills/eof/SKILL.md"
out="$(run_ap "$(printf '%s\n' '*** Begin Patch' '*** Update File: skills/eof/SKILL.md' '@@' '----' '*** End of File' '*** End Patch')" "$AP")"
assert_ap "AP-14b End of File のアンカーで末尾の --- を消す hunk は素通し（先頭の --- と取り違えない）" "" "$out"
out="$(run_ap "$(printf '%s\n' '*** Begin Patch' '*** Update File: skills/eof/SKILL.md' '@@' '----' '*** End of File ' '*** End Patch')" "$AP")"
assert_ap "AP-14c 末尾に空白のある End of File のアンカーも認める" "" "$out"

out="$(run_ap "$(cat <<'EOF'
*** Begin Patch
*** Update File: skills/demo/SKILL.md
@@
 # Demo
-
+
@@
 Line A
-Line B
+Line B two
*** End Patch
EOF
)" "$AP")"
assert_ap "AP-15 複数の hunk は前から順に適用でき、どちらも正しければ素通し" "" "$out"

# 2 つ目の hunk だけが不正（1 つ目で tags を直し、2 つ目が description を消す）。
# 1 つ目の hunk だけを適用して終わる（2 つ目を無視する）実装を捕まえる。2 つ目は 1 つ目の後ろにある
out="$(run_ap "$(cat <<'EOF'
*** Begin Patch
*** Update File: skills/multi/SKILL.md
@@
 name: multi
-tags: a
+tags: b
@@
-description: Does a thing. 使用する時に呼ぶ。
 ---
*** End Patch
EOF
)" "$AP")"
assert_ap "AP-15b 2 つ目の hunk だけが description を消す patch は止める（2 つ目の hunk も適用する）" deny "$out" "必須フィールド"

out="$(run_ap "$(cat <<'EOF'
*** Begin Patch
*** Environment ID: env-123
*** Add File: skills/z/SKILL.md
+---
+name: z
+---
+body
*** End Patch
EOF
)" "$AP")"
assert_ap "AP-16 Begin Patch の直後の Environment ID 行（0.160 の文法）を読み飛ばして検査する" deny "$out" "必須フィールド"

# 書式を解釈できない patch。SKILL.md に触れている疑いがあれば止め、無関係なら通す（全 patch を止めない）
assert_ap "AP-17 解釈できない patch が SKILL.md に触れている疑いなら Codex では止める" deny \
    "$(run_ap $'garbage\n*** Update File: skills/demo/SKILL.md' "$AP")" "Begin Patch"
assert_ap "AP-18 解釈できない patch でも SKILL.md に触れていなければ素通し" "" \
    "$(run_ap $'garbage without the target name' "$AP")"

# AP-19: .cwd が無く、相対パスの現ファイルを読む必要がある（前処理の失敗）
assert_ap "AP-19 .cwd が無く相対パスの現ファイルを読めない場合は止める" deny \
    "$(run_ap "$PATCH_NAME_REMOVED" "")" "前処理に失敗しました"

# AP-20: 絶対パスの patch も扱う（hook 入力の cwd に依らない）
out="$(run_ap "$(cat <<EOF
*** Begin Patch
*** Update File: $AP/skills/demo/SKILL.md
@@
 ---
-name: demo
 description: Does a thing. 使用する時に呼ぶ。
 ---
*** End Patch
EOF
)" "")"
assert_ap "AP-20 絶対パスの patch は .cwd が無くても検査できる" deny "$out" "必須フィールド"

# AP-21: ask 系（トリガー語なし）も Codex では deny。Claude Code の入力（apply_patch を使わない）には影響しない
out="$(run_ap "$(cat <<'EOF'
*** Begin Patch
*** Add File: skills/w/SKILL.md
+---
+name: w
+description: Does a thing.
+---
+body
*** End Patch
EOF
)" "$AP")"
assert_ap "AP-21 トリガー語の無い description の Add File は Codex では deny" deny "$out" "トリガー語"

# AP-22〜27c: 見出し・境界の空白と heredoc。Codex 0.160.0 の実パーサは見出しの前後を trim し、
# 3 種の heredoc を外して適用する（実測）。hook の解釈がずれると、実際に書かれる SKILL.md を検査せずに通す
out="$(run_ap "$(printf '%s\n' '*** Begin Patch' $'*** Add File: skills/x/SKILL.md \t' '+no frontmatter' '*** End Patch')" "$AP")"
assert_ap "AP-22 Add の見出しの末尾に空白・タブがあっても SKILL.md として検査する" deny "$out" "YAML frontmatter"

out="$(run_ap "$(printf '%s\n' '*** Begin Patch' '*** Update File: README-old.md' '*** Move to: skills/moved/SKILL.md ' \
    '@@' '-plain text' '+still no frontmatter' '*** End Patch')" "$AP")"
assert_ap "AP-23 Move to の末尾に空白があっても移動先の SKILL.md を検査する" deny "$out" "YAML frontmatter"

out="$(run_ap "$(printf '%s\n' '*** Begin Patch' $'*** Update File: skills/demo/SKILL.md\t' '@@' ' ---' '-name: demo' \
    ' description: Does a thing. 使用する時に呼ぶ。' ' ---' '*** End Patch')" "$AP")"
assert_ap "AP-24 Update の見出しの末尾にタブがあっても name 行の削除を止める" deny "$out" "必須フィールド"

# Add / Delete の後ろでは、行頭が空白の見出しも見出しになる（Update の本文の中だけは文脈行。AP-27b）
out="$(run_ap "$(printf '%s\n' '*** Begin Patch' '*** Add File: notes.md' '+hello' ' *** Add File: skills/x/SKILL.md' \
    '+no frontmatter' '*** End Patch')" "$AP")"
assert_ap "AP-25 [Add の後] 行頭が空白の Add 見出しも SKILL.md として検査する" deny "$out" "YAML frontmatter"
out="$(run_ap "$(printf '%s\n' '*** Begin Patch' '*** Delete File: README-old.md' ' *** Add File: skills/x/SKILL.md' \
    '+no frontmatter' '*** End Patch')" "$AP")"
assert_ap "AP-25 [Delete の後] 行頭が空白の Add 見出しも SKILL.md として検査する" deny "$out" "YAML frontmatter"

for opener in '<<EOF' "<<'EOF'" '<<"EOF"'; do
    out="$(run_ap "$(printf '%s\n' "$opener" '*** Begin Patch' '*** Update File: skills/demo/SKILL.md' '@@' '-Line A' \
        '+Line A2' '*** End Patch' 'EOF')" "$AP")"
    assert_ap "AP-26 heredoc（${opener}）で包んだ正しい patch は素通し" "" "$out"
done
out="$(run_ap "$(cat <<'PATCH'
<<'EOF'
*** Begin Patch
*** Update File: skills/demo/SKILL.md
@@
 ---
-name: demo
 description: Does a thing. 使用する時に呼ぶ。
 ---
*** End Patch
EOF
PATCH
)" "$AP")"
assert_ap "AP-26b heredoc で包んだ不正な patch は中身を検査して止める" deny "$out" "必須フィールド"

out="$(run_ap "$(printf '%s\n' '  *** Begin Patch  ' '  *** Environment ID: env-1  ' '  *** Update File: skills/demo/SKILL.md  ' \
    '@@' '-Line A' '+Line A2' '  *** End Patch  ')" "$AP")"
assert_ap "AP-27 境界と見出しの前後に空白がある正しい patch は素通し" "" "$out"

# Update の本文の中の行頭が空白の ' ***' は文脈行（notes.md の中身）で、見出しにも patch の終わりにもしない。
# notes.md は SKILL.md でないので hook は読まない（fixture 不要）
out="$(run_ap "$(printf '%s\n' '*** Begin Patch' '*** Update File: notes.md' '@@' ' *** Add File: skills/q/SKILL.md' \
    '+added' '*** End Patch')" "$AP")"
assert_ap "AP-27b Update の本文中の ' *** Add File:' は文脈行で、SKILL.md の追加にしない" "" "$out"
out="$(run_ap "$(printf '%s\n' '*** Begin Patch' '*** Update File: notes.md' '@@' ' *** End Patch' '+x' \
    '*** Update File: skills/demo/SKILL.md' '@@' ' ---' '-name: demo' ' description: Does a thing. 使用する時に呼ぶ。' \
    ' ---' '*** End Patch')" "$AP")"
assert_ap "AP-27c Update の本文中の ' *** End Patch' で解析を打ち切らず、後ろの SKILL.md も検査する" deny "$out" "必須フィールド"

# AP-28・LC-1〜3: SKILL.md の判定は大文字小文字を区別しない。macOS の APFS は区別しないので、
# skill.md と指定しても SKILL.md が書き換わる
out="$(run_ap "$(printf '%s\n' '*** Begin Patch' '*** Add File: skills/x/skill.md' '+no frontmatter' '*** End Patch')" "$AP")"
assert_ap "AP-28 小文字の skill.md の Add も SKILL.md として検査する" deny "$out" "YAML frontmatter"
out="$(run_ap "$(printf '%s\n' '*** Begin Patch' '*** Add File: skills/x/my-skill.md' '+no frontmatter' '*** End Patch')" "$AP")"
assert_ap "AP-28b my-skill.md は SKILL.md ではない（素通し）" "" "$out"
assert_ap "AP-28c 解釈できない patch が小文字の skill.md に触れている疑いでも止める" deny \
    "$(run_ap $'garbage\n*** Update File: skills/demo/skill.md' "$AP")" "Begin Patch"
assert_equal "LC-1 小文字の skill.md の Write も検査する（frontmatter 無しは ask）" "ask" \
    "$(decision_of "$(printf '%s' "$(lint_write /fx/skills/demo/skill.md $'no frontmatter here\n')" | bash "$LINT_HOOK" 2>/dev/null)")"
out="$(printf '%s' "$(lint_write /fx/skills/demo/my-skill.md $'no frontmatter here\n')" | bash "$LINT_HOOK" 2>/dev/null; echo "${PIPESTATUS[1]}" >"$RC_FILE")"
assert_hook_empty "LC-2 my-skill.md の Write は検査しない（素通し）" "$out"
out="$(printf '%s' "$(lint_write /fx/skills/_template/skill.md $'no frontmatter here\n')" | bash "$LINT_HOOK" 2>/dev/null; echo "${PIPESTATUS[1]}" >"$RC_FILE")"
assert_hook_empty "LC-3 _template/skill.md は大文字小文字を問わず検査対象外（素通し）" "$out"

# PF-1・PF-2: 前処理のエラーは実行ごとの一時ファイル（TMPDIR）に書き、終了時に消す。固定パス /tmp/skill-lint-err を
# 使うと、並行して走る別の hook の失敗の理由を出し、残骸も残る。偽の python3 は失敗し、その時点の TMPDIR の
# 中身を stderr に書く（固定パスなら一覧が空、実行ごとの一時ファイルならその名前が出る）
PF_BIN="$WORK/pf-bin"
PF_TMP="$WORK/pf-tmp"
mkdir -p "$PF_BIN" "$PF_TMP"
cat >"$PF_BIN/python3" <<'EOF'
#!/bin/bash
echo "FAKE-PY-FAIL in-tmpdir=[$(ls "$TMPDIR")]" >&2
exit 1
EOF
chmod +x "$PF_BIN/python3"
pf_run() {  # $1=入力 JSON → hook の出力
    printf '%s' "$1" | PATH="$PF_BIN:$PATH" TMPDIR="$PF_TMP" bash "$LINT_HOOK" 2>/dev/null
}
out="$(pf_run "$(lint_patch "$PATCH_NAME_REMOVED" "$AP" 1)")"
assert_equal "PF-1 apply_patch の前処理（python）の失敗は Codex では deny" "deny" "$(decision_of "$out")"
assert_contains "PF-1 理由に前処理のエラーを出す" "$(reason_of "$out")" "FAKE-PY-FAIL"
assert_not_contains "PF-1 エラーは実行ごとの一時ファイル（TMPDIR）に書く" "$(reason_of "$out")" "in-tmpdir=[]"
assert_equal "PF-1 終わった後に TMPDIR に一時ファイルを残さない" "0" "$(ls -A "$PF_TMP" | wc -l | tr -d ' ')"
out="$(pf_run "$LINT_EDIT_OK")"
assert_equal "PF-2 Edit の前処理（python）の失敗は ask" "ask" "$(decision_of "$out")"
assert_contains "PF-2 理由に前処理のエラーを出す" "$(reason_of "$out")" "FAKE-PY-FAIL"
assert_not_contains "PF-2 エラーは実行ごとの一時ファイル（TMPDIR）に書く" "$(reason_of "$out")" "in-tmpdir=[]"
assert_equal "PF-2 終わった後に TMPDIR に一時ファイルを残さない" "0" "$(ls -A "$PF_TMP" | wc -l | tr -d ' ')"

# --- BG-1〜3: 大きな SKILL.md でも判定を出す ---
# 本文を環境変数で子プロセスに渡すと、awk が Argument list too long で落ちる。echo | awk で awk が早く exit すると、
# 書き手が SIGPIPE を受けて set -e で hook ごと落ちる（どちらも判定が出ずに素通し）
mkdir -p "$AP/skills/big"
{ printf '%s\n' '---' 'name: big' 'description: Does a thing. 使用する時に呼ぶ。' '---' '# Big'
  i=0; while [[ $i -lt 30000 ]]; do printf 'line %d padding padding padding padding\n' "$i"; i=$((i + 1)); done; } >"$AP/skills/big/SKILL.md"
assert_equal "前提: BG-1 の SKILL.md は 1 MB を超える" "yes" "$([[ $(wc -c <"$AP/skills/big/SKILL.md") -gt 1048576 ]] && echo yes || echo no)"
out="$(run_ap "$(printf '%s\n' '*** Begin Patch' '*** Update File: skills/big/SKILL.md' '@@' ' ---' '-name: big' \
    ' description: Does a thing. 使用する時に呼ぶ。' ' ---' '*** End Patch')" "$AP")"
assert_ap "BG-1 1 MB を超える SKILL.md の name 行を消す patch は止める" deny "$out" "必須フィールド"
big_body="$(i=0; while [[ $i -lt 20000 ]]; do echo "body line $i"; i=$((i + 1)); done)"
out="$(printf '%s' "$(lint_write /fx/skills/demo/SKILL.md "$(printf '%s\n%s' $'---\nname: demo\n---' "$big_body")")" | bash "$LINT_HOOK" 2>/dev/null)"
assert_equal "BG-2 description の無い 200 KB の SKILL.md の Write は deny" "deny" "$(decision_of "$out")"
out="$(printf '%s' "$(lint_write /fx/skills/demo/SKILL.md "$(printf '%s\n%s' $'---\nname: demo\ndescription: Does a thing.\nlicense: x' "$big_body")")" | bash "$LINT_HOOK" 2>/dev/null)"
assert_equal "BG-3 閉じの --- が無い 200 KB の SKILL.md の Write は ask（素通しにしない）" "ask" "$(decision_of "$out")"

# =====================================================================
# SY: hook-check-scripts-sync.sh（SessionStart。~/.claude/scripts/ の未同期を通知する）
# =====================================================================
# .installed-from が指す install 元が shared/ 移行前（claude/scripts だけ）でも移行後（shared/scripts）でも
# 解決できること。どちらも解決できないと hook は「差分なし」と区別できない形で黙って終わり、
# 未同期の警告が出なくなる（fail-open）。移行前のブランチにメインチェックアウトがある間は
# 前者になるので、旧レイアウトも検査対象に残す
SYNC_HOOK="$REPO_ROOT/shared/scripts/hook-check-scripts-sync.sh"

# $1=名前, $2=repo のレイアウト, $3=インストール済みの内容（repo 側の内容は常に repo-body）
#   old  = claude/scripts だけ / new = shared/scripts だけ / both = shared 実体 + claude の互換 symlink
# sandbox HOME のパスを返す
make_sync_fixture() {
    local name="$1" layout="$2" installed_body="$3"
    local base="$WORK/sy-$name"
    rm -rf "$base"
    mkdir -p "$base/repo" "$base/home/.claude/scripts"
    case "$layout" in
        old)
            mkdir -p "$base/repo/claude/scripts"
            printf '%s\n' repo-body > "$base/repo/claude/scripts/hook-a.sh"
            ;;
        new)
            mkdir -p "$base/repo/shared/scripts"
            printf '%s\n' repo-body > "$base/repo/shared/scripts/hook-a.sh"
            ;;
        both)
            mkdir -p "$base/repo/shared/scripts" "$base/repo/claude"
            printf '%s\n' repo-body > "$base/repo/shared/scripts/hook-a.sh"
            ln -s ../shared/scripts "$base/repo/claude/scripts"
            ;;
    esac
    printf '%s\n' "$installed_body" > "$base/home/.claude/scripts/hook-a.sh"
    chmod +x "$base/home/.claude/scripts/hook-a.sh"
    printf '%s\t%s\t%s\n' "$base/repo" main abc1234 > "$base/home/.claude/scripts/.installed-from"
    echo "$base/home"
}

run_sync_hook() {  # $1=sandbox HOME
    HOME="$1" bash "$SYNC_HOOK" </dev/null 2>&1
    echo "$?" > "$RC_FILE"
}

# 値の取り出しは jq で行う（出力全体への部分文字列照合は、無関係な文言への偶然マッチを拾う）
sync_context() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }

for layout in old new both; do
    h="$(make_sync_fixture "stale-$layout" "$layout" local-edit)"
    out="$(run_sync_hook "$h")"
    ctx="$(sync_context "$out")"
    assert_contains "SY-1 [$layout] インストール済みが repo と違えば hook-a.sh を名指しして警告する" "$ctx" "hook-a.sh (差分あり)"
    assert_contains "SY-2 [$layout] 警告は 1 件と数える" "$ctx" "1 件が repo と一致していません"
    assert_contains "SY-3 [$layout] 同期の警告でも hook は exit 0 で終わる（通知でありガードではない）" "rc=$(cat "$RC_FILE")" "rc=0"

    h="$(make_sync_fixture "sync-$layout" "$layout" repo-body)"
    out="$(run_sync_hook "$h")"
    assert_hook_empty "SY-4 [$layout] 同期済みなら何も出さず exit 0（毎セッション鳴る通知は無視される）" "$out"
done

echo
echo "${pass_count} passed / ${fail_count} failed"
[[ "$fail_count" -eq 0 ]] || exit 1
