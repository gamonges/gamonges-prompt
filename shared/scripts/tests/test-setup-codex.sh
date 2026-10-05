#!/usr/bin/env bash
# setup.sh（install / migrate / status / uninstall）と verify-skills.sh の「配置」の挙動テスト。
# ガードレールの hook は test-guardrails.sh が担い、本ファイルは配置処理（symlink・実体コピー・
# マーカーブロック・生成物）を担う。
#
# 対象はいずれも「壊れても何も起きない」型の不具合で、通常の動作確認では検知できない:
#   - 定数の付け替え漏れで install が 0 件コピーして成功する
#   - verify が 0 件を数えて 0 == 0 で pass する
#   - 参照先が存在しないファイルを読んで、例外を握りつぶして既定値で続行する
# そのため期待値は setup.sh / verify の実装に頼らず、ls / find / jq / awk で独立に数える。
# 件数を使う assert は、先に「0 でないこと」を assert して空振りを防ぐ。
#
# HOME は sandbox に差し替える。setup.sh と verify-skills.sh は node を使わないので、
# HOME を差し替えても mise shim の node が壊れる問題（auto-memory）には当たらない。
# 本ファイルも node を呼ばない。
#
# tests/ に置く理由は test-guardrails.sh と同じ（scripts/ 直下の glob から外すため）。
# `bash shared/scripts/tests/test-setup-codex.sh` で起動する。
#
# 依存: bash / git / jq / perl / awk

# set -e は使わない。1 件目の失敗で残りが走らなくなると、Red フェーズで全件の失敗を確認できない
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_SHARED="$REPO_ROOT/shared"
SETUP="$REPO_ROOT/setup.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass_count=0
fail_count=0

pass() { echo -e "${GREEN}[PASS]${NC} $1"; pass_count=$((pass_count + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; fail_count=$((fail_count + 1)); }

WORK="$(mktemp -d)"
cleanup() {
    chmod -R u+rwx "$WORK" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

assert_eq() {  # $1=ラベル, $2=期待値, $3=実際の値
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1"
        echo "       期待: ${2:-（空）}" >&2
        echo "       実際: ${3:-（空）}" >&2
    fi
}

assert_contains() {  # $1=ラベル, $2=実出力, $3=期待する部分文字列
    if [[ "$2" == *"$3"* ]]; then
        pass "$1"
    else
        fail "$1"
        echo "       期待する部分文字列: $3" >&2
        echo "       実際の出力（末尾 15 行）:" >&2
        printf '%s\n' "$2" | tail -n 15 | sed 's/^/         /' >&2
    fi
}

assert_not_contains() {  # $1=ラベル, $2=実出力, $3=含まれてはいけない部分文字列
    if [[ "$2" != *"$3"* ]]; then
        pass "$1"
    else
        fail "$1"
        echo "       含まれてはいけない部分文字列: $3" >&2
    fi
}

# 期待件数が 0 のとき 0 == 0 で通る比較を失敗にする。件数を突き合わせる assert はこれを使う
assert_count_eq() {  # $1=ラベル, $2=期待件数（0 は不可）, $3=実際の件数
    if [[ ! "$2" =~ ^[0-9]+$ || "$2" -eq 0 ]]; then
        fail "$1（期待件数が 0 または数値でない: ${2:-空}。0 == 0 で通る空振りを避けるため失敗扱い）"
        return
    fi
    assert_eq "$1" "$2" "$3"
}

# 0 件を数えた状態で件数比較が通る空振りを防ぐ。件数を使う assert の前に必ず通す
assert_positive() {  # $1=ラベル, $2=件数
    if [[ "$2" =~ ^[0-9]+$ && "$2" -gt 0 ]]; then
        pass "$1"
    else
        fail "$1（件数が 0 または数値でない: ${2:-空}）"
    fi
}

git_init() {
    mkdir -p "$1"
    git -C "$1" init -q
    git -C "$1" config user.email test@example.com
    git -C "$1" config user.name test-setup-codex
    git -C "$1" config commit.gpgsign false
}

# symlink 自身の inode。「触っていない」ことを、リンクの作り直し（rm → ln -s）の有無で見る。
# readlink の文字列比較では、同じ先へ張り直されても区別できない
inode() { perl -e 'print((lstat $ARGV[0])[1])' "$1"; }

new_home() {  # $1=名前 → sandbox HOME のパスを返す
    local h="$WORK/home-$1"
    rm -rf "$h"
    mkdir -p "$h"
    echo "$h"
}

# setup.sh を sandbox HOME で実行する。出力は $WORK/out.log、終了コードは $WORK/rc に残す
# （$(...) のサブシェルから親へ値を渡す経路が無いため。test-guardrails.sh の RC_FILE と同じ理由）
run_setup() {  # $1=HOME, $2...=setup.sh の引数
    local h="$1"
    shift
    HOME="$h" bash "$SETUP" "$@" >"$WORK/out.log" 2>&1
    echo $? >"$WORK/rc"
}
last_rc() { cat "$WORK/rc"; }
last_out() { cat "$WORK/out.log"; }

# --- 独立した件数 ---------------------------------------------------------
# repo の skill 数（_ プレフィックスは雛形扱いで除く）。setup.sh / verify の数え方とは別に、
# 配置元の実ディレクトリを直接数える
count_repo_skills() {
    local n=0 d b
    for d in "$REPO_SHARED"/skills/*/; do
        [[ -d "$d" ]] || continue
        b="$(basename "$d")"
        [[ "$b" == _* ]] && continue
        n=$((n + 1))
    done
    echo "$n"
}

# repo の agent 数（README.md を除く .md）。find の起点は実ディレクトリでなければならない
# （symlink を起点にすると find は降りない）。shared/agents は実体
count_repo_agents() {
    [[ -d "$REPO_SHARED/agents" ]] || { echo 0; return; }
    find "$REPO_SHARED/agents" -name '*.md' -type f ! -name README.md | wc -l | tr -d ' '
}

count_repo_scripts() {
    local n=0 f
    for f in "$REPO_SHARED"/scripts/*.sh "$REPO_SHARED"/scripts/*.py; do
        [[ -f "$f" ]] && n=$((n + 1))
    done
    echo "$n"
}

# frontmatter（先頭の --- から次の ---）の中に disable-model-invocation: true があるか。
# 本文のコードブロックに同じ行があっても数えない（verify の check 5 も frontmatter だけを見る）
frontmatter_has_disable() {  # $1=SKILL.md
    awk '
        NR == 1 { if ($0 != "---") exit 1; next }
        /^---$/ { exit }
        /^disable-model-invocation:[[:space:]]*true/ { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$1"
}

# verify の check 5 が「skillOverrides 由来で listing から外れた skill」として数える件数を、
# settings.json と SKILL.md から独立に数える。verify は frontmatter の disable を先に数えるので、
# 両方に当たる skill は skillOverrides 側には数えない
count_expected_overrides() {
    local settings="$REPO_ROOT/claude/settings.json" key f n=0
    [[ -f "$settings" ]] || { echo 0; return; }
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        [[ "$key" == _* ]] && continue
        f="$REPO_SHARED/skills/$key/SKILL.md"
        [[ -f "$f" ]] || continue
        frontmatter_has_disable "$f" && continue
        n=$((n + 1))
    done < <(jq -r '(.skillOverrides // {}) | to_entries[]
        | select(.value == "name-only" or .value == "user-invocable-only" or .value == "off")
        | .key' "$settings")
    echo "$n"
}

EXPECTED_SKILLS="$(count_repo_skills)"
EXPECTED_AGENTS="$(count_repo_agents)"
EXPECTED_SCRIPTS="$(count_repo_scripts)"

echo "== 前提: repo の件数（独立に数えた値）=="
assert_positive "shared/skills に skill がある" "$EXPECTED_SKILLS"
assert_positive "shared/agents に agent がある" "$EXPECTED_AGENTS"
assert_positive "shared/scripts に script がある" "$EXPECTED_SCRIPTS"

# ===========================================================================
# C-1: install / migrate が ~/.claude/{skills,agents} を shared/ へ張る
# ===========================================================================
echo "== C-1: Claude 側の install / migrate のリンク先 =="

H1="$(new_home t1)"
run_setup "$H1" install
assert_eq "install は成功する" "0" "$(last_rc)"

linked=0
for d in "$REPO_SHARED"/skills/*/; do
    [[ -d "$d" ]] || continue
    b="$(basename "$d")"
    [[ "$b" == _* ]] && continue
    [[ "$(readlink "$H1/.claude/skills/$b" 2>/dev/null)" == "$REPO_SHARED/skills/$b/" ]] && linked=$((linked + 1))
done
assert_count_eq "~/.claude/skills の全 skill が shared/skills/<name>/ を指す" "$EXPECTED_SKILLS" "$linked"
assert_eq "_template は install されない" "no" "$([[ -e "$H1/.claude/skills/_template" || -L "$H1/.claude/skills/_template" ]] && echo yes || echo no)"

agent_linked=0
while IFS= read -r -d '' md; do
    [[ "$(readlink "$H1/.claude/agents/$(basename "$md")" 2>/dev/null)" == "$md" ]] && agent_linked=$((agent_linked + 1))
done < <(find "$REPO_SHARED/agents" -name '*.md' -type f ! -name README.md -print0 2>/dev/null)
assert_count_eq "~/.claude/agents の全 agent が shared/agents 配下を指す" "$EXPECTED_AGENTS" "$agent_linked"

# 2 回目の install は正しいリンクを作り直さない（symlink が無い窓を開けない。併走セッションの skill ロードが失敗しうる）
ino_before="$(inode "$H1/.claude/skills/ask")"
agent_before="$(inode "$H1/.claude/agents/test-auditor.md")"
run_setup "$H1" install
assert_eq "2 回目の install も成功する" "0" "$(last_rc)"
assert_positive "inode を取れている（skills/ask）" "${ino_before:-0}"
assert_eq "2 回目の install は skills/ask のリンクを作り直さない" "$ino_before" "$(inode "$H1/.claude/skills/ask")"
assert_eq "2 回目の install は agents/test-auditor.md のリンクを作り直さない" "$agent_before" "$(inode "$H1/.claude/agents/test-auditor.md")"

# migrate: 旧 claude/ を指すリンクを shared/ に張り替える（skills だけでなく agents も）
H2="$(new_home t2)"
mkdir -p "$H2/.claude/skills" "$H2/.claude/agents"
AGENT_SRC="$(find "$REPO_SHARED/agents" -name test-auditor.md -type f 2>/dev/null | head -1)"
if [[ -z "$AGENT_SRC" ]]; then
    fail "shared/agents に test-auditor.md がある（migrate のケースを組み立てられない）"
else
    AGENT_REL="${AGENT_SRC#"$REPO_SHARED/agents/"}"
    ln -s "$REPO_ROOT/claude/skills/ask/" "$H2/.claude/skills/ask"
    ln -s "$REPO_ROOT/claude/agents/$AGENT_REL" "$H2/.claude/agents/test-auditor.md"
    run_setup "$H2" migrate
    assert_eq "migrate は成功する" "0" "$(last_rc)"
    assert_eq "migrate は旧 claude/skills/ask/ を shared/skills/ask/ に張り替える" \
        "$REPO_SHARED/skills/ask/" "$(readlink "$H2/.claude/skills/ask" 2>/dev/null)"
    assert_eq "migrate は旧 claude/agents/ のリンクを shared/agents/ に張り替える" \
        "$AGENT_SRC" "$(readlink "$H2/.claude/agents/test-auditor.md" 2>/dev/null)"
fi

# 衝突: Claude 側は従来どおり実ディレクトリを退避し、リンク先を問わず symlink を張り替える。
# Codex 側の skip と取り違えると、Claude 側の既存ユーザーの skill が黙って残る/消える
H3="$(new_home t3)"
mkdir -p "$H3/.claude/skills/ask"
echo "user-owned" >"$H3/.claude/skills/ask/SKILL.md"
ln -s "$WORK/unrelated-target" "$H3/.claude/skills/grill"
run_setup "$H3" install
assert_eq "衝突があっても install は成功する" "0" "$(last_rc)"
backup_n="$(find "$H3/.claude/skills" -maxdepth 1 -name 'ask.backup.*' | wc -l | tr -d ' ')"
assert_eq "実ディレクトリ ask は ask.backup.* へ退避される" "1" "$backup_n"
assert_eq "退避した ask の中身は変わらない" "user-owned" \
    "$(cat "$H3"/.claude/skills/ask.backup.*/SKILL.md 2>/dev/null)"
assert_eq "退避後の ask は shared/skills/ask/ を指すリンクになる" \
    "$REPO_SHARED/skills/ask/" "$(readlink "$H3/.claude/skills/ask" 2>/dev/null)"
assert_eq "無関係な先を指す symlink（grill）は Claude 側では張り替える" \
    "$REPO_SHARED/skills/grill/" "$(readlink "$H3/.claude/skills/grill" 2>/dev/null)"

# ===========================================================================
# C-2: pull しただけ（install 前）でも旧パス claude/{skills,agents,scripts} が解決できる
# ===========================================================================
echo "== C-2: 互換 symlink（旧パスが解決できる）=="

# 期待値は readlink の文字列ではなく「解決できるか」。../ の数を間違えると文字列は一見正しくても切れる
# 解決できるかを yes / no で返す。`test -f …; assert … "$?"` は、$? が直前の条件の結果であることに依存して壊れやすい
resolves() { [[ -f "$1" ]] && echo yes || echo no; }
assert_eq "旧パス claude/skills/ask/SKILL.md が解決できる" "yes" "$(resolves "$REPO_ROOT/claude/skills/ask/SKILL.md")"
if [[ -n "$AGENT_SRC" ]]; then
    assert_eq "旧パス claude/agents/<カテゴリ>/test-auditor.md が解決できる" "yes" "$(resolves "$REPO_ROOT/claude/agents/$AGENT_REL")"
else
    fail "旧パス claude/agents/ の解決を確かめられない（AGENT_SRC が空）"
fi
assert_eq "旧パス claude/scripts/hook-confirm-destructive-git.sh が解決できる" "yes" "$(resolves "$REPO_ROOT/claude/scripts/hook-confirm-destructive-git.sh")"

# ===========================================================================
# C-3: scripts の実体コピーと、前回 sha の判定（前回 sha が旧/新どちらのレイアウトでもローカル改変を判定する）
# ===========================================================================
echo "== C-3: scripts の実体コピー =="

copied=0
exec_ok=0
for f in "$REPO_SHARED"/scripts/*.sh "$REPO_SHARED"/scripts/*.py; do
    [[ -f "$f" ]] || continue
    t="$H1/.claude/scripts/$(basename "$f")"
    cmp -s "$f" "$t" && copied=$((copied + 1))
    [[ -x "$t" ]] && exec_ok=$((exec_ok + 1))
done
assert_count_eq "shared/scripts の全件が ~/.claude/scripts に内容一致でコピーされる" "$EXPECTED_SCRIPTS" "$copied"
assert_count_eq "コピーされた scripts は実行可能" "$EXPECTED_SCRIPTS" "$exec_ok"
assert_eq ".installed-from の 1 列目は install 元のチェックアウト" "$REPO_ROOT" \
    "$(cut -f1 "$H1/.claude/scripts/.installed-from" 2>/dev/null)"

# 前回 sha の判定用の最小 repo を作る。本物の setup.sh を複製し、レイアウトだけを持つ
# $1=dir, $2=hook の中身, $3="old" なら claude/scripts、"new" なら shared/scripts に置く
f13_commit() {
    local dir="$1" body="$2" layout="$3"
    rm -rf "$dir/claude/scripts" "$dir/shared/scripts"
    if [[ "$layout" == old ]]; then
        mkdir -p "$dir/claude/scripts"
        printf '%s\n' "$body" >"$dir/claude/scripts/hook-a.sh"
    else
        mkdir -p "$dir/shared/scripts"
        printf '%s\n' "$body" >"$dir/shared/scripts/hook-a.sh"
    fi
    git -C "$dir" add -A >/dev/null 2>&1
    git -C "$dir" commit -q -m "f13 $layout $body" >/dev/null 2>&1
    git -C "$dir" rev-parse --short HEAD
}

# 結果はグローバルの F13_REPO / F13_SHA_OLD / F13_SHA_NEW / F13_SHA_NEW2 に入れる。
# $(f13_setup …) で呼ぶとサブシェルになり、代入が親に戻らず sha が空のまま空振りする
f13_setup() {  # $1=名前
    local dir="$WORK/f13-$1"
    F13_REPO="$dir"
    git_init "$dir"
    cp "$SETUP" "$dir/setup.sh"
    mkdir -p "$dir/shared/skills/demo" "$dir/shared/agents" "$dir/claude"
    printf '%s\n' '---' 'name: demo' 'description: demo' '---' >"$dir/shared/skills/demo/SKILL.md"
    printf '%s\n' '{}' >"$dir/claude/settings.json"
    : >"$dir/shared/global-rules.md"
    F13_SHA_OLD="$(f13_commit "$dir" 'echo v1' old)"
    F13_SHA_NEW="$(f13_commit "$dir" 'echo v2' new)"
    F13_SHA_NEW2="$(f13_commit "$dir" 'echo v3' new)"
}

f13_home() {  # $1=名前, $2=repo, $3=.installed-from の sha, $4=インストール済みの hook の中身
    local h
    h="$(new_home "f13-$1")"
    mkdir -p "$h/.claude/scripts"
    printf '%s\n' "$4" >"$h/.claude/scripts/hook-a.sh"
    chmod +x "$h/.claude/scripts/hook-a.sh"
    printf '%s\t%s\t%s\n' "$2" main "$3" >"$h/.claude/scripts/.installed-from"
    echo "$h"
}

f13_backups() { find "$1/.claude/scripts" -maxdepth 1 -name 'hook-a.sh.backup.*' | wc -l | tr -d ' '; }

f13_setup base
assert_positive "前回 sha の判定用の fixture repo に 3 つの commit がある（sha が空でない）" "$([[ -n "$F13_SHA_OLD" && -n "$F13_SHA_NEW" && -n "$F13_SHA_NEW2" ]] && echo 1 || echo 0)"
SETUP_BACKUP="$SETUP"
SETUP="$F13_REPO/setup.sh"

# (i) 前回 sha が旧レイアウト（claude/scripts）で、インストール済みが前回から改変されている → 退避する
H="$(f13_home old "$F13_REPO" "$F13_SHA_OLD" 'echo local-edit')"
run_setup "$H" install
assert_eq "前回 sha の判定(i) 旧レイアウトの sha: install は成功する" "0" "$(last_rc)"
assert_eq "前回 sha の判定(i) 旧レイアウトの sha: ローカル改変を退避する" "1" "$(f13_backups "$H")"
assert_eq "前回 sha の判定(i) 旧レイアウトの sha: 新しい内容に置き換わる" "echo v3" "$(cat "$H/.claude/scripts/hook-a.sh" 2>/dev/null)"

# (ii) 前回 sha が新レイアウト（shared/scripts）で、インストール済みが前回から改変されている → 退避する。
#      旧パスだけを探す実装は「ファイルが無い = 初回」と誤判定し、改変を黙って上書きする
H="$(f13_home new "$F13_REPO" "$F13_SHA_NEW" 'echo local-edit')"
run_setup "$H" install
assert_eq "前回 sha の判定(ii) 新レイアウトの sha: install は成功する" "0" "$(last_rc)"
assert_eq "前回 sha の判定(ii) 新レイアウトの sha: ローカル改変を退避する" "1" "$(f13_backups "$H")"

# (iii) 前回 sha の内容とインストール済みが一致（repo が更新されただけ）→ 退避しない。
#       常時点灯する警告は無視されるようになるので、標準運用（編集 → install）で退避を積まない
H="$(f13_home clean "$F13_REPO" "$F13_SHA_NEW" 'echo v2')"
run_setup "$H" install
assert_eq "前回 sha の判定(iii) 改変なし: install は成功する" "0" "$(last_rc)"
assert_eq "前回 sha の判定(iii) 改変なし: 退避を作らない" "0" "$(f13_backups "$H")"
assert_eq "前回 sha の判定(iii) 改変なし: 新しい内容に置き換わる" "echo v3" "$(cat "$H/.claude/scripts/hook-a.sh" 2>/dev/null)"

SETUP="$SETUP_BACKUP"

# ===========================================================================
# C-4: verify-skills.sh は互換 symlink 経由でも shared/ 直でも repo ルートを正しく導出する
# ===========================================================================
echo "== C-4: verify-skills.sh のパス導出 =="

EXPECTED_OVERRIDES="$(count_expected_overrides)"
assert_positive "settings.json の skillOverrides に repo skill の隠し指定がある（check 5 の観測点）" "$EXPECTED_OVERRIDES"

for entry in claude/scripts/verify-skills.sh shared/scripts/verify-skills.sh; do
    out="$(HOME="$H1" bash "$REPO_ROOT/$entry" 2>&1)"
    rc=$?
    assert_eq "verify（${entry}）は fail なしで終わる" "0" "$rc"
    # skill の glob が空だと check 1 が expected=0=installed で pass する。数が実数と一致することを見る
    assert_contains "verify（${entry}）が数えた skill 数が実数と一致する" "$out" "(${EXPECTED_SKILLS} skills verified)"
    # check 5 は settings.json の読み込み失敗を握りつぶして overrides を空にする。
    # パスを誤ると件数が 0 に落ちるだけで気づけないので、件数そのものを見る
    assert_contains "verify（${entry}）の check 5 が settings.json の skillOverrides を読めている" \
        "$out" "skillOverrides ${EXPECTED_OVERRIDES} 件"
    # check 6 は成功時に何も出さず、スキップ時だけ warn を出す。verify が起動できていない
    # （出力が空）場合にも「スキップされていない」が通ってしまうので、最後まで走ったことを条件にする
    if [[ "$out" == *"skills verified)"* ]]; then
        assert_not_contains "verify（${entry}）の check 6 が settings.json 不在でスキップされていない" \
            "$out" "check 6 (hook の実体) をスキップしました"
    else
        fail "verify（${entry}）が最後まで走っていない（check 6 の判定を飛ばした）"
    fi
done

# install 元の worktree が削除された状態。verify はここで警告を出して続行する契約。
# bash 3.2 は `$from_dir（` のように変数名の直後に全角文字が続くと変数名の一部と読み、
# set -u 下で unbound variable になって verify 全体が異常終了していた（警告も後続の check も出ない）
H_GONE="$(new_home verify-gone)"
run_setup "$H_GONE" install
printf '%s\t%s\t%s\n' "$WORK/removed-checkout" main abc1234 >"$H_GONE/.claude/scripts/.installed-from"
out="$(HOME="$H_GONE" /bin/bash "$REPO_SHARED/scripts/verify-skills.sh" 2>&1)"
assert_contains "install 元が削除されていれば警告する" "$out" "指すチェックアウトがありません"
assert_contains "install 元の警告の後も verify が最後まで走る（後続の check が飛ばない）" "$out" "skills verified)"

# ===========================================================================
# status / uninstall: 定数の付け替え漏れは「0 件を処理して成功」になる
# ===========================================================================
echo "== status / uninstall =="

run_setup "$H1" status
assert_eq "status は成功する" "0" "$(last_rc)"
linked_lines="$(last_out | grep -c 'リンク済み' || true)"
# settings.json 1 行 + skills + agents
assert_count_eq "status が全リンクを「リンク済み」と表示する" "$((EXPECTED_SKILLS + EXPECTED_AGENTS + 1))" "$linked_lines"

# install が何も置いていないと「0 件残る」が空振りで通る。撤去前に置かれていた件数を先に見る
pre_skills="$(find "$H1/.claude/skills" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
pre_agents="$(find "$H1/.claude/agents" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
assert_count_eq "uninstall の前に install 済みの skills がある" "$EXPECTED_SKILLS" "$pre_skills"
assert_count_eq "uninstall の前に install 済みの agents がある" "$EXPECTED_AGENTS" "$pre_agents"

run_setup "$H1" uninstall
assert_eq "uninstall は成功する" "0" "$(last_rc)"
left_skills="$(find "$H1/.claude/skills" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
left_agents="$(find "$H1/.claude/agents" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
left_scripts="$(find "$H1/.claude/scripts" -mindepth 1 -maxdepth 1 -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "uninstall は install した skills を全件撤去する" "0" "$left_skills"
assert_eq "uninstall は install した agents を全件撤去する" "0" "$left_agents"
assert_eq "uninstall は install した scripts を全件撤去する" "0" "$left_scripts"
assert_eq "uninstall は settings.json のリンクを撤去する" "no" \
    "$([[ -e "$H1/.claude/settings.json" || -L "$H1/.claude/settings.json" ]] && echo yes || echo no)"

# ===========================================================================
# C-7: gen-agents.py（agents の .md → Codex の custom agent の TOML）
# ===========================================================================
echo "== C-7: gen-agents.py =="

GEN="$REPO_ROOT/codex/gen-agents.py"
# 生成器は setup.sh と同じ python3（macOS の 3.9）で走らせる。3.9 には tomllib が無いので、
# 生成物の TOML としての正しさは別の経路で見る（下の 2 つのオラクル）
PY313="$(command -v python3.13 || true)"

# オラクル 1: TOML の basic string の文法そのものを正規表現で見る。生成器の json.dumps には頼らない。
# 制御文字（U+0000-0008, 000A-001F, 007F）の生の混入と、不正なエスケープを弾く
toml_grammar_bad_lines() {  # $1=TOML を置いたディレクトリ → 不正な行の数
    python3 - "$1" <<'PY'
import glob, os, re, sys
ok = re.compile(
    r'^(name|description|sandbox_mode|developer_instructions) = "('
    r'[^"\\\x00-\x08\x0a-\x1f\x7f]|\\(?:["\\bfnrt]|u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8}))*"$'
)
bad = 0
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.toml"))):
    with open(f, encoding="utf-8") as fp:
        for line in fp.read().split("\n"):
            if line and not line.startswith("#") and not ok.match(line):
                bad += 1
print(bad)
PY
}

# オラクル 2: tomllib（3.11 以降）で実際に読み、本文が 1 文字も欠けずに往復することを見る。
# 本文は md から独立に取り出す。DEL・引用符・バックスラッシュのエスケープを取り違えると、
# 文法は通っても読み戻した本文が元と違う
toml_roundtrip() {  # $1=TOML のディレクトリ, $2=md のディレクトリ → "ok <件数>" か "NG ..."
    "$PY313" - "$1" "$2" <<'PY'
import os, sys, tomllib
out_dir, src_dir = sys.argv[1], sys.argv[2]
n = 0
for dirpath, _d, files in os.walk(src_dir):
    for fname in sorted(files):
        if not fname.endswith(".md") or fname == "README.md":
            continue
        stem = fname[:-3]
        with open(os.path.join(dirpath, fname), encoding="utf-8") as fp:
            lines = fp.read().split("\n")
        end = lines.index("---", 1)
        body = "\n".join(lines[end + 1:]).strip("\n")
        with open(os.path.join(out_dir, stem + ".toml"), "rb") as fp:
            d = tomllib.load(fp)
        if d["name"] != stem or not d["developer_instructions"].endswith(body):
            print("NG %s: 本文が往復しない" % stem)
            sys.exit(0)
        n += 1
print("ok %d" % n)
PY
}

mkdir -p "$WORK/gen-main/src/01-x" "$WORK/gen-main/src/02-y"
G="$WORK/gen-main"

cat >"$G/src/01-x/fx-reader.md" <<'EOF'
---
name: fx-reader
description: Reads things: carefully
tools: Read, Glob, Grep, Bash
skills:
  - fx-skill
  - fx-second
---

# Reader

Line one.

Line two.
EOF

cat >"$G/src/01-x/fx-writer.md" <<'EOF'
---
name: fx-writer
description: Writes things
tools: Read, Write, Edit, Bash
model: opus
---
Body.
EOF

cat >"$G/src/02-y/fx-escape.md" <<'EOF'
---
name: fx-escape
description: >
  Folded one
  and two.

  Second paragraph.
tools: Read
---
He said "hi" \ and ''' and @DEL@: x@TAB@tab 日本語
EOF
perl -i -pe 's/\@DEL\@/\x7f/g; s/\@TAB\@/\t/g' "$G/src/02-y/fx-escape.md"

# tools が無い agent は Claude Code では全ツールを継承する。read-only にしない（書けなくなる）
cat >"$G/src/02-y/fx-notools.md" <<'EOF'
---
name: fx-notools
description: No tools key
---
Inherit.
EOF

# tools をリスト形式で書いた場合。書き込み系があれば read-only にしない
cat >"$G/src/02-y/fx-listwrite.md" <<'EOF'
---
name: fx-listwrite
description: List form
tools:
  - Read
  - MultiEdit
---
List.
EOF

# 書き込み系ツールは Write・MultiEdit だけではない。Edit 単独・NotebookEdit 単独でも read-only にしない
# （WRITE_TOOLS から 1 つ外す回帰を、Write との併記や実データの 1 件では捕まえられない）
printf '%s\n' '---' 'name: fx-editonly' 'description: Edit only' 'tools: Read, Edit' '---' 'E.' >"$G/src/02-y/fx-editonly.md"
printf '%s\n' '---' 'name: fx-nbonly' 'description: Notebook only' 'tools: Read, NotebookEdit' '---' 'N.' >"$G/src/02-y/fx-nbonly.md"

printf '%s\n' 'not a frontmatter file' >"$G/src/README.md"

python3 "$GEN" --repo-root "$G" --src "$G/src" --out "$G/out" >"$WORK/gen.out" 2>&1
assert_eq "生成は成功する" "0" "$?"
assert_eq "README.md は出力されず、agent 7 件が出力される" "7" "$(find "$G/out" -name '*.toml' | wc -l | tr -d ' ')"

cat >"$G/expected-reader.toml" <<'EOF'
# generated-by: gamonges-prompt setup.sh — source: src/01-x/fx-reader.md — 手で編集しない
name = "fx-reader"
description = "Reads things: carefully"
sandbox_mode = "read-only"
developer_instructions = "作業を始める前に ~/.agents/skills/fx-skill/SKILL.md を読む。読めなければ作業を始めずに停止して報告する。\n作業を始める前に ~/.agents/skills/fx-second/SKILL.md を読む。読めなければ作業を始めずに停止して報告する。\n\n# Reader\n\nLine one.\n\nLine two."
EOF
cat >"$G/expected-writer.toml" <<'EOF'
# generated-by: gamonges-prompt setup.sh — source: src/01-x/fx-writer.md — 手で編集しない
name = "fx-writer"
description = "Writes things"
developer_instructions = "Body."
EOF
cat >"$G/expected-escape.toml" <<'EOF'
# generated-by: gamonges-prompt setup.sh — source: src/02-y/fx-escape.md — 手で編集しない
name = "fx-escape"
description = "Folded one and two.\nSecond paragraph."
sandbox_mode = "read-only"
developer_instructions = "He said \"hi\" \\ and ''' and \u007f: x\ttab 日本語"
EOF
cat >"$G/expected-notools.toml" <<'EOF'
# generated-by: gamonges-prompt setup.sh — source: src/02-y/fx-notools.md — 手で編集しない
name = "fx-notools"
description = "No tools key"
developer_instructions = "Inherit."
EOF
cat >"$G/expected-editonly.toml" <<'EOF'
# generated-by: gamonges-prompt setup.sh — source: src/02-y/fx-editonly.md — 手で編集しない
name = "fx-editonly"
description = "Edit only"
developer_instructions = "E."
EOF
cat >"$G/expected-nbonly.toml" <<'EOF'
# generated-by: gamonges-prompt setup.sh — source: src/02-y/fx-nbonly.md — 手で編集しない
name = "fx-nbonly"
description = "Notebook only"
developer_instructions = "N."
EOF
cat >"$G/expected-listwrite.toml" <<'EOF'
# generated-by: gamonges-prompt setup.sh — source: src/02-y/fx-listwrite.md — 手で編集しない
name = "fx-listwrite"
description = "List form"
developer_instructions = "List."
EOF

for pair in reader:fx-reader writer:fx-writer escape:fx-escape notools:fx-notools listwrite:fx-listwrite editonly:fx-editonly nbonly:fx-nbonly; do
    exp="${pair%%:*}"
    nm="${pair##*:}"
    if diff -u "$G/expected-$exp.toml" "$G/out/$nm.toml" >"$WORK/gen.diff" 2>&1; then
        pass "C-7 $nm の出力が期待する TOML と一致する"
    else
        fail "C-7 $nm の出力が期待する TOML と一致する"
        sed 's/^/       /' "$WORK/gen.diff" >&2
    fi
done

assert_eq "オラクル 1: 生成した TOML の文字列が TOML の basic string の文法に合う（生の制御文字・不正なエスケープ無し）" \
    "0" "$(toml_grammar_bad_lines "$G/out")"
if [[ -n "$PY313" ]]; then
    assert_eq "オラクル 2: tomllib で読め、本文が 1 文字も欠けずに往復する（DEL・引用符・バックスラッシュ）" \
        "ok 7" "$(toml_roundtrip "$G/out" "$G/src")"
else
    echo "[INFO] python3.13 が無いので tomllib のオラクルは省略（文法のオラクルは実行済み）"
fi

# 失敗系: 検証エラーは exit 非 0 で、出力を 1 件も書かない（半端な出力を残すと install が古い物と新しい物を混ぜる）
expect_gen_fail() {  # $1=ラベル, $2=想定するエラー文の一部, $3=fixture の名前（$WORK/gen-$3/src を使う）
    local root="$WORK/gen-$3"
    python3 "$GEN" --repo-root "$root" --src "$root/src" --out "$root/out" >"$WORK/gen.out" 2>&1
    local rc=$?
    if [[ "$rc" -ne 0 ]]; then pass "$1: exit 非 0"; else fail "$1: exit 非 0（実際は ${rc}）"; fi
    assert_contains "$1: 理由を出す" "$(cat "$WORK/gen.out")" "$2"
    assert_eq "$1: 何も書かない" "0" "$(find "$root/out" -name '*.toml' 2>/dev/null | wc -l | tr -d ' ')"
}

mkdir -p "$WORK/gen-unknown/src"
printf '%s\n' '---' 'name: ok-one' 'description: valid' 'tools: Read' '---' 'Body.' >"$WORK/gen-unknown/src/ok-one.md"
printf '%s\n' '---' 'name: bad-key' 'description: has color' 'color: red' '---' 'Body.' >"$WORK/gen-unknown/src/bad-key.md"
# 有効な agent と無効な agent が同じ木にある。有効な側だけが書かれる半端な状態を残さない
expect_gen_fail "G-1 未知の frontmatter キー" "未知の frontmatter キー" unknown

mkdir -p "$WORK/gen-mismatch/src"
printf '%s\n' '---' 'name: other-name' 'description: mismatch' '---' 'Body.' >"$WORK/gen-mismatch/src/file-name.md"
expect_gen_fail "G-2 name とファイル名の不一致" "一致しません" mismatch

mkdir -p "$WORK/gen-dup/src/a" "$WORK/gen-dup/src/b"
printf '%s\n' '---' 'name: same' 'description: first' '---' 'A.' >"$WORK/gen-dup/src/a/same.md"
printf '%s\n' '---' 'name: same' 'description: second' '---' 'B.' >"$WORK/gen-dup/src/b/same.md"
expect_gen_fail "G-3 name の重複" "重複" dup

mkdir -p "$WORK/gen-builtin/src"
printf '%s\n' '---' 'name: explorer' 'description: shadows a built-in' '---' 'X.' >"$WORK/gen-builtin/src/explorer.md"
expect_gen_fail "G-4 Codex の組み込み agent と同じ name" "組み込み agent" builtin

mkdir -p "$WORK/gen-nodesc/src"
printf '%s\n' '---' 'name: nodesc' '---' 'X.' >"$WORK/gen-nodesc/src/nodesc.md"
expect_gen_fail "G-5 description が無い" "description がありません" nodesc

mkdir -p "$WORK/gen-quoted/src"
printf '%s\n' '---' 'name: quoted' 'description: "quoted value"' '---' 'X.' >"$WORK/gen-quoted/src/quoted.md"
expect_gen_fail "G-6 引用符つきの値（YAML と生成器の解釈が割れうる）" "未対応" quoted

mkdir -p "$WORK/gen-blockstyle/src"
printf '%s\n' '---' 'name: blockstyle' 'description: >+' '  keep trailing newlines' '---' 'X.' >"$WORK/gen-blockstyle/src/blockstyle.md"
expect_gen_fail "G-8 未対応のブロック指示子（>+）を文字列 '>+' として通さない" "未対応" blockstyle

mkdir -p "$WORK/gen-comment/src"
printf '%s\n' '---' 'name: comment' 'description: has a # comment-like part' '---' 'X.' >"$WORK/gen-comment/src/comment.md"
expect_gen_fail "G-7 値に ' #' がある（YAML ではコメントになる）" "コメント" comment

# 実データ: 現行の agents 全件を生成し、最小パーサが実際の frontmatter を通ることと、
# read-only の分類が独立に数えた件数と一致することを見る
REAL_OUT="$WORK/gen-real-out"
python3 "$GEN" --out "$REAL_OUT" >"$WORK/gen.out" 2>&1
assert_eq "実データの生成は成功する" "0" "$?"
assert_count_eq "実データの全 agent が出力される" "$EXPECTED_AGENTS" "$(find "$REAL_OUT" -name '*.toml' | wc -l | tr -d ' ')"
headers=0
for f in "$REAL_OUT"/*.toml; do
    case "$(head -1 "$f")" in "# generated-by: gamonges-prompt setup.sh — source: shared/agents/"*) headers=$((headers + 1)) ;; esac
done
assert_count_eq "実データの全件の 1 行目が生成ヘッダ（uninstall・orphan 判定の目印）" "$EXPECTED_AGENTS" "$headers"
assert_eq "実データ: TOML の文法に合わない行が無い" "0" "$(toml_grammar_bad_lines "$REAL_OUT")"
if [[ -n "$PY313" ]]; then
    assert_eq "実データ: tomllib で全件読め、全件の本文が往復する" "ok $EXPECTED_AGENTS" \
        "$(toml_roundtrip "$REAL_OUT" "$REPO_SHARED/agents")"
fi

# read-only の件数を md から独立に数える（tools: の行に書き込み系ツールが無い agent）
expected_ro=0
while IFS= read -r -d '' md; do
    tools_line="$(awk 'NR==1{next} /^---$/{exit} /^tools:/{print; exit}' "$md")"
    case "$tools_line" in
        *Write*|*Edit*) ;;  # MultiEdit・NotebookEdit も "Edit" を含むので、この 2 つで 4 種すべてに当たる
        "") ;;
        *) expected_ro=$((expected_ro + 1)) ;;
    esac
done < <(find "$REPO_SHARED/agents" -name '*.md' -type f ! -name README.md -print0 2>/dev/null)
actual_ro="$(grep -l '^sandbox_mode = "read-only"' "$REAL_OUT"/*.toml 2>/dev/null | wc -l | tr -d ' ')"
assert_count_eq "実データ: read-only の件数が md から独立に数えた件数と一致する" "$expected_ro" "$actual_ro"

# ===========================================================================
# C-8〜C-16: setup.sh の Codex 側の配置（~/.agents/skills・~/.codex/agents・AGENTS.md・hooks.json）
# ===========================================================================
echo "== C-8〜C-16: Codex 側の配置 =="

# 「自前」の定義（setup.sh と同じ）: command が /.claude/scripts/ を含む。settings.json の command は
# リテラルの絶対パス（/Users/<user>/.claude/scripts/…）なので、$HOME での前方一致にすると sandbox HOME で 0 件になる
SELF_COUNT="$(jq '[.hooks[][] | .hooks[] | (.command // "") | select(contains("/.claude/scripts/"))] | length' "$REPO_ROOT/claude/settings.json")"
assert_positive "前提: settings.json から自前 hook を抽出できている（0 件だと以降の全ケースが空振りする）" "$SELF_COUNT"

# 実機と同じ並びの hooks.json: 各イベントの先頭に settings.json と同一の自前グループ、その後ろに Orca・Muxy
make_real_hooks_json() {  # $1=出力ファイル
    jq '
      def selfhook: ((.command // "") | contains("/.claude/scripts/"));
      { hooks: (
          .hooks
          | with_entries(.value |= [ .[] | select(.hooks | length > 0 and all(.[]; selfhook)) ])
          | with_entries(select(.value | length > 0))
        ) }
      | .hooks |= (
          . as $h
          | reduce ["UserPromptSubmit","PreToolUse","PostToolUse","SessionStart","Stop"][] as $e ($h;
              .[$e] = ((.[$e] // []) + [
                {hooks: [{type: "command", command: ("/opt/orca/orca-hook.sh " + $e)}]},
                {matcher: "*", hooks: [{type: "command", command: ("/opt/muxy/muxy-codex-hook.sh " + $e)}]}
              ])))
    ' "$REPO_ROOT/claude/settings.json" >"$1"
}

# 自前以外の hook の (event, グループ index, hook index, command)。位置が変わると Codex の信頼が外れる
non_self_positions() {  # $1=hooks.json
    jq -c '[.hooks | to_entries[] | .key as $e | .value | to_entries[] | .key as $g
            | .value.hooks | to_entries[]
            | select((.value.command // "") | contains("/.claude/scripts/") | not)
            | [$e, $g, .key, .value.command]]' "$1"
}
self_hook_count() {  # $1=hooks.json
    jq '[.hooks[][] | .hooks[] | (.command // "") | select(contains("/.claude/scripts/"))] | length' "$1"
}

# sandbox HOME に実機相当の ~/.codex と ~/.agents/skills を作る
make_codex_home() {  # $1=名前 → HOME のパスを返す
    local h
    h="$(new_home "cx-$1")"
    mkdir -p "$h/.codex/agents" "$h/.agents/skills/review" "$h/.agents/skills/other-tool"
    make_real_hooks_json "$h/.codex/hooks.json"
    printf '%s\n' '# my personal rules' 'be nice' >"$h/.codex/AGENTS.md"
    printf '%s\n' 'name = "custom-hand"' 'description = "hand written"' 'developer_instructions = "x"' >"$h/.codex/agents/custom-hand.toml"
    # repo の agent と同名の手書き TOML（生成ヘッダが無い）。上書きしてはいけない
    printf '%s\n' 'name = "test-auditor"' 'description = "mine"' 'developer_instructions = "mine"' >"$h/.codex/agents/test-auditor.toml"
    printf '%s\n' 'someone else' >"$h/.agents/skills/review/SKILL.md"
    printf '%s\n' 'someone else' >"$h/.agents/skills/other-tool/SKILL.md"
    # 同じ repo の別 worktree を指していたリンク（自分のリンク）と、無関係なパスを指すリンク（他者のリンク）
    ln -s "$WORK/other-wt/shared/skills/ask/" "$h/.agents/skills/ask"
    ln -s "$WORK/unrelated/grill/" "$h/.agents/skills/grill"
    # 移行前（claude/skills 配下）の worktree が張った自分のリンク。パターンの片側（*/claude/skills/<name>/）だけが
    # 落ちる回帰を、文字列の一致ではなく挙動で捕まえる
    ln -s "$WORK/other-wt/claude/skills/design/" "$h/.agents/skills/design"
    echo "$h"
}

HC="$(make_codex_home main)"
positions_before="$(non_self_positions "$HC/.codex/hooks.json")"
assert_eq "前提: fixture の hooks.json に自前 hook が settings.json と同数ある（抽出が 0 件で全ケースが空振りするのを防ぐ）" "$SELF_COUNT" "$(self_hook_count "$HC/.codex/hooks.json")"
assert_positive "前提: fixture の自前以外の hook がある（Orca・Muxy 相当）" "$(echo "$positions_before" | jq 'length')"
cp -p "$HC/.codex/hooks.json" "$WORK/hooks.json.snapshot"
mtime_before="$(perl -e 'print((stat $ARGV[0])[9])' "$HC/.codex/hooks.json")"
sleep 1

run_setup "$HC" install
assert_eq "C-8 Codex を含む install は成功する" "0" "$(last_rc)"
install_out="$(last_out)"

# --- skills（~/.agents/skills）---
cx_linked=0
for d in "$REPO_SHARED"/skills/*/; do
    [[ -d "$d" ]] || continue
    b="$(basename "$d")"
    [[ "$b" == _* ]] && continue
    [[ "$(readlink "$HC/.agents/skills/$b" 2>/dev/null)" == "$REPO_SHARED/skills/$b/" ]] && cx_linked=$((cx_linked + 1))
done
# review（実ディレクトリ）と grill（無関係なパスを指すリンク）は衝突なので張られない
assert_count_eq "C-9 ~/.agents/skills に shared/skills/<name>/ を指すリンクが張られる（衝突の 2 件を除く）" "$((EXPECTED_SKILLS - 2))" "$cx_linked"
assert_eq "C-9 _template は配置されない" "no" "$([[ -e "$HC/.agents/skills/_template" || -L "$HC/.agents/skills/_template" ]] && echo yes || echo no)"
assert_eq "C-9 別 worktree を指していた自分のリンク（ask）は今のチェックアウトへ張り替わる" \
    "$REPO_SHARED/skills/ask/" "$(readlink "$HC/.agents/skills/ask" 2>/dev/null)"
assert_eq "C-9 旧 claude/skills を指していた自分のリンク（design）も今のチェックアウトへ張り替わる" \
    "$REPO_SHARED/skills/design/" "$(readlink "$HC/.agents/skills/design" 2>/dev/null)"
assert_eq "C-9 同名の実ディレクトリ review は変わらない（中身も）" "someone else" "$(cat "$HC/.agents/skills/review/SKILL.md" 2>/dev/null)"
assert_eq "C-9 review は symlink にならない" "no" "$([[ -L "$HC/.agents/skills/review" ]] && echo yes || echo no)"
assert_eq "C-9 repo に無い名前の実ディレクトリ other-tool は変わらない" "someone else" "$(cat "$HC/.agents/skills/other-tool/SKILL.md" 2>/dev/null)"
assert_eq "C-9 無関係なパスを指すリンク（grill）は変わらない" "$WORK/unrelated/grill/" "$(readlink "$HC/.agents/skills/grill" 2>/dev/null)"
assert_eq "C-9 退避（.backup.*）を ~/.agents/skills に作らない（走査対象の中に作ると同名 skill が 2 つになる）" "0" \
    "$(find "$HC/.agents/skills" -maxdepth 1 -name '*.backup.*' | wc -l | tr -d ' ')"
assert_contains "C-9 衝突した review を warn で知らせる（Claude 側の「✓ review」に偶然当たらないよう、配置先のパスで見る）" "$install_out" ".agents/skills/review"
assert_contains "C-9 他者のリンクに当たった grill を warn で知らせる" "$install_out" ".agents/skills/grill"

# --- agents（~/.codex/agents の TOML）---
header_ok=0
for f in "$HC/.codex/agents/"*.toml; do
    [[ -f "$f" ]] || continue
    case "$(head -1 "$f")" in "# generated-by: gamonges-prompt setup.sh — source: "*) header_ok=$((header_ok + 1)) ;; esac
done
assert_count_eq "C-8 生成ヘッダつきの TOML が agent の数だけある（同名の手書き 1 件を除く）" "$((EXPECTED_AGENTS - 1))" "$header_ok"
assert_eq "C-8 手書き TOML（custom-hand）は変わらない" 'name = "custom-hand"' "$(head -1 "$HC/.codex/agents/custom-hand.toml")"
assert_eq "C-8 repo の agent と同名の手書き TOML（test-auditor）は上書きしない" 'description = "mine"' "$(sed -n 2p "$HC/.codex/agents/test-auditor.toml")"
assert_contains "C-8 同名の手書き TOML は warn で知らせる（配置先のパスで見る）" "$install_out" ".codex/agents/test-auditor.toml"
mkdir -p "$WORK/cx-gen-ref"
python3 "$REPO_ROOT/codex/gen-agents.py" --out "$WORK/cx-gen-ref" >/dev/null 2>&1
assert_eq "C-8 生成した TOML は生成器の出力と一致する（agent: ad-security-reviewer）" "0" \
    "$(cmp -s "$WORK/cx-gen-ref/ad-security-reviewer.toml" "$HC/.codex/agents/ad-security-reviewer.toml"; echo $?)"

# --- AGENTS.md ---
agents_md="$HC/.codex/AGENTS.md"
assert_eq "C-10 ブロック外の個人部分はそのまま残る" "# my personal rules
be nice" "$(sed -n '1,2p' "$agents_md")"
assert_eq "C-10 共通規約のブロックが 1 つ入る" "1" "$(grep -c -F '<!-- BEGIN gamonges-prompt: skills 共通規約 -->' "$agents_md")"
assert_eq "C-10 Codex 読み替え表のブロックが 1 つ入る" "1" "$(grep -c -F '<!-- BEGIN gamonges-prompt: codex 読み替え表 -->' "$agents_md")"
block_of() {  # $1=ファイル, $2=BEGIN 行, $3=END 行 → ブロックの中身（マーカーを除く）
    awk -v b="$2" -v e="$3" '$0 == e { on = 0 } on { print } $0 == b { on = 1 }' "$1"
}
assert_eq "C-10 共通規約ブロックの中身が shared/global-rules.md と一致する" "0" \
    "$(diff <(block_of "$agents_md" '<!-- BEGIN gamonges-prompt: skills 共通規約 -->' '<!-- END gamonges-prompt: skills 共通規約 -->') "$REPO_SHARED/global-rules.md" >/dev/null 2>&1; echo $?)"
assert_eq "C-10 読み替え表ブロックの中身が codex/codex-rules.md と一致する" "0" \
    "$(diff <(block_of "$agents_md" '<!-- BEGIN gamonges-prompt: codex 読み替え表 -->' '<!-- END gamonges-prompt: codex 読み替え表 -->') "$REPO_ROOT/codex/codex-rules.md" >/dev/null 2>&1; echo $?)"

# --- hooks.json: 実機と同じ並びなら初回の install から書き込まない ---
assert_eq "C-12 実機と同じ並びの hooks.json は内容が不変" "0" "$(cmp -s "$WORK/hooks.json.snapshot" "$HC/.codex/hooks.json"; echo $?)"
assert_eq "C-12 実機と同じ並びの hooks.json は書き込まれない（mtime 不変）" "$mtime_before" \
    "$(perl -e 'print((stat $ARGV[0])[9])' "$HC/.codex/hooks.json")"
assert_eq "C-12 退避（hooks.json.pre-install.*）を作らない" "0" \
    "$(find "$HC/.codex" -maxdepth 1 -name 'hooks.json.pre-install.*' | wc -l | tr -d ' ')"
assert_eq "C-12 自前以外の hook の (event, グループ index, hook index, command) が install 前後で同じ" \
    "$positions_before" "$(non_self_positions "$HC/.codex/hooks.json")"

# 2 回目の install は何も変えない（ブロックが重複しない・TOML を書き直さない・hooks.json に触れない）
snap_agents_md="$(cat "$agents_md")"
snap_toml_mtime="$(perl -e 'print((stat $ARGV[0])[9])' "$HC/.codex/agents/ad-security-reviewer.toml")"
assert_positive "前提: 1 回目の install で生成された TOML の mtime を取れている（無いと不変の比較が空 == 空で通る）" "${snap_toml_mtime:-0}"
sleep 1
run_setup "$HC" install
assert_eq "C-8 2 回目の install も成功する" "0" "$(last_rc)"
assert_eq "C-10 2 回目の install で AGENTS.md は変わらない（ブロックが重複しない）" "$snap_agents_md" "$(cat "$agents_md")"
assert_eq "C-8 2 回目の install は差分の無い TOML を書き直さない（mtime 不変）" "$snap_toml_mtime" \
    "$(perl -e 'print((stat $ARGV[0])[9])' "$HC/.codex/agents/ad-security-reviewer.toml")"
assert_eq "C-12 2 回目の install でも hooks.json は不変" "0" "$(cmp -s "$WORK/hooks.json.snapshot" "$HC/.codex/hooks.json"; echo $?)"

# --- hooks.json: 自前グループを 1 つ古くした fixture（hook を 1 本外す）→ 同じ位置で差し替える ---
HS="$(make_codex_home stale)"
jq '.hooks.UserPromptSubmit[0].hooks |= map(select(.command | contains("hook-detect-correction.sh") | not))' \
    "$HS/.codex/hooks.json" >"$WORK/hs.json" && cp "$WORK/hs.json" "$HS/.codex/hooks.json"
assert_eq "前提: 古い fixture は自前 hook が 1 本少ない" "$((SELF_COUNT - 1))" "$(self_hook_count "$HS/.codex/hooks.json")"
pos_stale_before="$(non_self_positions "$HS/.codex/hooks.json")"
run_setup "$HS" install
assert_eq "C-13 自前グループが古い hooks.json でも install は成功する" "0" "$(last_rc)"
assert_eq "C-13 自前 hook が全件（settings.json と同数）に戻る" "$SELF_COUNT" "$(self_hook_count "$HS/.codex/hooks.json")"
assert_eq "C-13 差し替えは同じ位置で行われ、自前以外の位置は変わらない" "$pos_stale_before" "$(non_self_positions "$HS/.codex/hooks.json")"
assert_eq "C-13 差し替えの前に hooks.json.pre-install.* へ退避する" "1" \
    "$(find "$HS/.codex" -maxdepth 1 -name 'hooks.json.pre-install.*' | wc -l | tr -d ' ')"
assert_contains "C-13 /hooks で信頼し直す案内を出す" "$(last_out)" "/hooks"

# --- hooks.json: 自前グループが 1 つも無い fixture → 各イベントの先頭に挿入し、全件の信頼し直しを案内 ---
HN="$(make_codex_home noself)"
jq '.hooks |= with_entries(.value |= map(select(.hooks | all(.[]; (.command // "") | contains("/.claude/scripts/") | not))))' \
    "$HN/.codex/hooks.json" >"$WORK/hn.json" && cp "$WORK/hn.json" "$HN/.codex/hooks.json"
assert_eq "前提: 自前グループの無い fixture は自前 hook が 0 本" "0" "$(self_hook_count "$HN/.codex/hooks.json")"
order_before="$(non_self_positions "$HN/.codex/hooks.json" | jq -c '[.[] | .[3]]')"
run_setup "$HN" install
assert_eq "C-13 自前グループが無い hooks.json でも install は成功する" "0" "$(last_rc)"
assert_eq "C-13 自前 hook が全件（settings.json と同数）入る" "$SELF_COUNT" "$(self_hook_count "$HN/.codex/hooks.json")"
assert_eq "C-13 自前グループは各イベントの先頭に入る（PreToolUse の 0 番目の matcher は Bash）" "Bash" \
    "$(jq -r '.hooks.PreToolUse[0].matcher' "$HN/.codex/hooks.json")"
assert_eq "C-13 自前以外の hook の相対的な並びは保たれる" "$order_before" \
    "$(non_self_positions "$HN/.codex/hooks.json" | jq -c '[.[] | .[3]]')"
assert_contains "C-13 グループの数が変わるイベントを名指しして、Orca・Muxy を含む全件の信頼し直しを案内する" "$(last_out)" "PreToolUse"
assert_contains "C-13 全件の信頼し直しが要ることを案内する" "$(last_out)" "全件"

# --- hooks.json: 触ってはいけない形と壊れた入力は、書き込まずエラー ---
HM="$(make_codex_home mixed)"
jq '.hooks.PreToolUse += [{hooks: [{type: "command", command: "/Users/x/.claude/scripts/hook-late.sh"}]}]' \
    "$HM/.codex/hooks.json" >"$WORK/hm.json" && cp "$WORK/hm.json" "$HM/.codex/hooks.json"
cp -p "$HM/.codex/hooks.json" "$WORK/hm.snapshot"
run_setup "$HM" install
assert_eq "C-14 先頭以外に自前 hook がある hooks.json は exit 非 0（推測で並べ替えない）" "1" "$([[ "$(last_rc)" != "0" ]] && echo 1 || echo 0)"
assert_eq "C-14 先頭以外に自前 hook がある hooks.json は書き換えない" "0" "$(cmp -s "$WORK/hm.snapshot" "$HM/.codex/hooks.json"; echo $?)"

HB="$(make_codex_home badjson)"
printf '%s' '{"hooks": {broken' >"$HB/.codex/hooks.json"
cp -p "$HB/.codex/hooks.json" "$WORK/hb.snapshot"
run_setup "$HB" install
assert_eq "C-14 壊れた JSON の hooks.json は exit 非 0" "1" "$([[ "$(last_rc)" != "0" ]] && echo 1 || echo 0)"
assert_eq "C-14 壊れた JSON の hooks.json は書き換えない（空や半端なファイルにしない）" "0" "$(cmp -s "$WORK/hb.snapshot" "$HB/.codex/hooks.json"; echo $?)"

# --- AGENTS.md: BEGIN だけがあって END が無い → 書き込まずエラー（BEGIN 以降の全消去を防ぐ）---
HE="$(make_codex_home noend)"
printf '%s\n' 'keep me' '<!-- BEGIN gamonges-prompt: skills 共通規約 -->' 'half written, no end marker' >"$HE/.codex/AGENTS.md"
cp -p "$HE/.codex/AGENTS.md" "$WORK/he.snapshot"
run_setup "$HE" install
assert_eq "C-10 END の無い AGENTS.md は exit 非 0" "1" "$([[ "$(last_rc)" != "0" ]] && echo 1 || echo 0)"
assert_eq "C-10 END の無い AGENTS.md は書き換えない" "0" "$(cmp -s "$WORK/he.snapshot" "$HE/.codex/AGENTS.md"; echo $?)"

# --- AGENTS.md が dotfiles への symlink でも、リンクを通常ファイルに置き換えて壊さない ---
HSL="$(make_codex_home symlink)"
mkdir -p "$WORK/dotfiles"
mv "$HSL/.codex/AGENTS.md" "$WORK/dotfiles/AGENTS.md"
ln -s "$WORK/dotfiles/AGENTS.md" "$HSL/.codex/AGENTS.md"
run_setup "$HSL" install
run_setup "$HSL" install
assert_eq "C-10 AGENTS.md が symlink のとき、install 後も symlink のまま" "yes" "$([[ -L "$HSL/.codex/AGENTS.md" ]] && echo yes || echo no)"
assert_eq "C-10 symlink のリンク先に、ブロックが 1 つずつ入る（2 回 install しても重複しない）" "2" \
    "$(grep -c -F -e '<!-- BEGIN gamonges-prompt:' "$WORK/dotfiles/AGENTS.md")"

# --- 生成元の無くなった生成物（agent の削除・改名）は install で消す。手書きは消さない ---
HO="$(make_codex_home orphan)"
printf '%s\n' "# generated-by: gamonges-prompt setup.sh — source: shared/agents/old/removed-agent.md — 手で編集しない" \
    'name = "removed-agent"' >"$HO/.codex/agents/removed-agent.toml"
run_setup "$HO" install
assert_eq "C-8 生成元の無くなった生成物（ヘッダつき）は install で削除される" "no" \
    "$([[ -e "$HO/.codex/agents/removed-agent.toml" ]] && echo yes || echo no)"
assert_eq "C-8 手書きの TOML は orphan 扱いで消さない" 'name = "custom-hand"' "$(head -1 "$HO/.codex/agents/custom-hand.toml")"

# --- hooks.json が無い ~/.codex: 自前の hook だけで新規に作る（退避は作らない）---
HNJ="$(new_home nohooksjson)"
mkdir -p "$HNJ/.codex"
run_setup "$HNJ" install
assert_eq "C-12 hooks.json が無くても install は成功する" "0" "$(last_rc)"
assert_eq "C-12 hooks.json が無ければ自前の hook 全件で新規に作る" "$SELF_COUNT" "$(self_hook_count "$HNJ/.codex/hooks.json" 2>/dev/null || echo 0)"
assert_eq "C-12 新規作成では退避を作らない" "0" "$(find "$HNJ/.codex" -maxdepth 1 -name 'hooks.json.pre-install.*' | wc -l | tr -d ' ')"

# --- scripts を更新したら、Codex の信頼の確認を案内する（信頼がスクリプトの中身に紐づく場合、hook がスキップされる）---
assert_contains "C-8 scripts を更新した install は /hooks の確認を案内する（初回は全件が新規）" "$install_out" "本更新しました"

# --- Claude 側の CLAUDE.md のブロック: 関数化（install_marker_block）の後も従来どおり ---
HCL="$(new_home claudemd)"
mkdir -p "$HCL/.claude"
printf '%s\n' 'my claude personal rules' >"$HCL/.claude/CLAUDE.md"
run_setup "$HCL" install
assert_eq "C-11 CLAUDE.md の個人部分は残る" "my claude personal rules" "$(head -1 "$HCL/.claude/CLAUDE.md")"
assert_eq "C-11 CLAUDE.md に共通規約ブロックが 1 つ入る" "1" "$(grep -c -F '<!-- BEGIN gamonges-prompt: skills 共通規約 -->' "$HCL/.claude/CLAUDE.md")"
assert_eq "C-11 CLAUDE.md のブロックの中身が shared/global-rules.md と一致する" "0" \
    "$(diff <(block_of "$HCL/.claude/CLAUDE.md" '<!-- BEGIN gamonges-prompt: skills 共通規約 -->' '<!-- END gamonges-prompt: skills 共通規約 -->') "$REPO_SHARED/global-rules.md" >/dev/null 2>&1; echo $?)"
snap_claude_md="$(cat "$HCL/.claude/CLAUDE.md")"
run_setup "$HCL" install
assert_eq "C-11 2 回目の install で CLAUDE.md は変わらない（ブロックが重複しない）" "$snap_claude_md" "$(cat "$HCL/.claude/CLAUDE.md")"
printf '%s\n' 'keep me' '<!-- BEGIN gamonges-prompt: skills 共通規約 -->' 'half written' >"$HCL/.claude/CLAUDE.md"
cp -p "$HCL/.claude/CLAUDE.md" "$WORK/hcl.snapshot"
run_setup "$HCL" install
assert_eq "C-11 END の無い CLAUDE.md は exit 非 0（従来は BEGIN 以降を全消去していた）" "1" "$([[ "$(last_rc)" != "0" ]] && echo 1 || echo 0)"
assert_eq "C-11 END の無い CLAUDE.md は書き換えない" "0" "$(cmp -s "$WORK/hcl.snapshot" "$HCL/.claude/CLAUDE.md"; echo $?)"

# --- ~/.codex が無い HOME では Codex の処理を飛ばし、Claude 側の install は従来どおり成功する ---
HNC="$(new_home nocodex)"
run_setup "$HNC" install
assert_eq "C-16 ~/.codex が無くても install は成功する" "0" "$(last_rc)"
assert_contains "C-16 Codex への展開を省略したことを INFO で出す" "$(last_out)" "~/.codex が無いので Codex への展開を省略"
assert_eq "C-16 ~/.codex を作らない" "no" "$([[ -e "$HNC/.codex" ]] && echo yes || echo no)"
assert_eq "C-16 ~/.agents を作らない" "no" "$([[ -e "$HNC/.agents" ]] && echo yes || echo no)"
assert_count_eq "C-16 Claude 側の skills は配置される" "$EXPECTED_SKILLS" "$(find "$HNC/.claude/skills" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"

# --- status: [Codex] 節 ---
run_setup "$HC" status
assert_eq "C-17 status は成功する" "0" "$(last_rc)"
status_out="$(last_out)"
assert_contains "C-17 status に [Codex] 節がある" "$status_out" "[Codex]"
# 件数は install の結果と一致する（衝突の 2 件と手書きの 1 件が差になる）
assert_contains "C-17 status の Skills の件数が install 結果と一致する" "$status_out" "Skills: $((EXPECTED_SKILLS - 2))/${EXPECTED_SKILLS} 件リンク済み"
assert_contains "C-17 status の Agents の件数が install 結果と一致する" "$status_out" "Agents: $((EXPECTED_AGENTS - 1))/${EXPECTED_AGENTS} 件"
assert_contains "C-17 status の hooks.json の自前 hook の本数が実数と一致する" "$status_out" "自前の hook ${SELF_COUNT} 本"
# ~/.codex が無い HOME でも status は最後まで走る（bash 3.2 の空配列 + set -u で途中で落ちない）
run_setup "$HNC" status
assert_eq "C-17 ~/.codex が無い HOME でも status は成功する" "0" "$(last_rc)"
assert_contains "C-17 ~/.codex が無いことを status が示す" "$(last_out)" "~/.codex が存在しません"

# --- uninstall: 自分が置いたものだけを撤去し、他者のものを残す ---
# 別 worktree を指すリンク（自分のリンク）を 1 つ作っておく。完全一致だけで判定すると撤去できず、切れたリンクが残る
rm "$HC/.agents/skills/ask" && ln -s "$WORK/other-wt2/shared/skills/ask/" "$HC/.agents/skills/ask"
rm "$HC/.agents/skills/design" && ln -s "$WORK/other-wt2/claude/skills/design/" "$HC/.agents/skills/design"
run_setup "$HC" uninstall
assert_eq "C-15 Codex を含む uninstall は成功する" "0" "$(last_rc)"
assert_eq "C-15 自分の symlink（別 worktree を指すものを含む）は撤去される" "0" \
    "$(find "$HC/.agents/skills" -maxdepth 1 -type l ! -name grill | wc -l | tr -d ' ')"
assert_eq "C-15 同名の実ディレクトリ review は残る" "someone else" "$(cat "$HC/.agents/skills/review/SKILL.md" 2>/dev/null)"
assert_eq "C-15 other-tool は残る" "someone else" "$(cat "$HC/.agents/skills/other-tool/SKILL.md" 2>/dev/null)"
assert_eq "C-15 無関係なパスを指すリンク grill は残る" "$WORK/unrelated/grill/" "$(readlink "$HC/.agents/skills/grill" 2>/dev/null)"
assert_eq "C-15 生成ヘッダつきの TOML は撤去される" "0" \
    "$(grep -l '^# generated-by: gamonges-prompt setup.sh' "$HC/.codex/agents/"*.toml 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "C-15 手書きの TOML は残る" 'name = "custom-hand"' "$(head -1 "$HC/.codex/agents/custom-hand.toml")"
assert_eq "C-15 repo の agent と同名の手書き TOML も残る" 'description = "mine"' "$(sed -n 2p "$HC/.codex/agents/test-auditor.toml")"
assert_eq "C-15 AGENTS.md のブロックは撤去され、個人部分は残る" "# my personal rules
be nice" "$(grep -v '^$' "$HC/.codex/AGENTS.md")"
assert_eq "C-15 自前 hook は撤去される" "0" "$(self_hook_count "$HC/.codex/hooks.json")"
assert_eq "C-15 自前以外の hook（Orca・Muxy 相当）の相対的な並びは残る" \
    "$(echo "$positions_before" | jq -c '[.[] | .[3]]')" "$(non_self_positions "$HC/.codex/hooks.json" | jq -c '[.[] | .[3]]')"
assert_contains "C-15 uninstall は先頭の自前グループの除去で位置がずれるため、信頼し直しを案内する" "$(last_out)" "/hooks"

# ===========================================================================
# C-24〜C-28: verify-skills.sh の Codex 検査（check 8・10・11・12）と対称性 check（7(1)）
# ===========================================================================
echo "== C-24〜C-28: verify-skills.sh の Codex 検査 =="

# verify の出力から、見出し「== check <番号>:」から次の見出しまでを切り出す（色コードは落とす）。
# 「該当の check だけが fail / warn になる」ことを見るため、check ごとに分けて判定する
verify_run() {  # $1=HOME, $2=verify のパス（既定は repo のもの）→ 出力。終了コードは $WORK/verify.rc
    # $(...) の代入の後の PIPESTATUS は内側のパイプラインを指さないので、終了コードは内側で書く
    local out
    out="$({ HOME="$1" bash "${2:-$REPO_SHARED/scripts/verify-skills.sh}" 2>&1; echo "$?" >"$WORK/verify.rc"; } | LC_ALL=C sed 's/\x1b\[[0-9;]*m//g')"
    printf '%s' "$out"
}
verify_section() {  # $1=出力, $2=check の番号（7(1) 等を含む）
    printf '%s\n' "$1" | awk -v n="$2" '
        /^== check / { on = (index($0, "== check " n ":") == 1) }
        on { print }'
}
count_tag() {  # $1=テキスト, $2=[WARN] / [FAIL] / [PASS]
    printf '%s\n' "$1" | grep -c -F -e "$2" || true
}

# config.toml の信頼キー（実機と同じ形式）を、hooks.json の自前 hook の位置から独立に組み立てる。
# 形式: [hooks.state."<hooks.json の絶対パス>:<event の snake_case>:<グループ index>:<hook index>"]
make_trust_toml() {  # $1=hooks.json, $2=出力する config.toml
    jq -r --arg path "$1" '
        def snake: gsub("(?<a>[a-z])(?<b>[A-Z])"; "\(.a)_\(.b)") | ascii_downcase;
        .hooks | to_entries[] | .key as $e | .value | to_entries[] | .key as $g
        | .value.hooks | to_entries[]
        | select((.value.command // "") | contains("/.claude/scripts/"))
        | "[hooks.state.\"\($path):\($e | snake):\($g):\(.key)\"]\ntrusted_hash = \"sha256:test\"\n"' "$1" >"$2"
}

# 健全な状態（install 直後 + 信頼済み）を作る。衝突の review・grill は実機と同じく残る
make_verify_home() {  # $1=名前 → HOME のパス
    local h
    h="$(make_codex_home "v-$1")"
    # repo の agent と同名の手書き TOML は、install が skip する意図的な衝突（setup 側のテストで検査済み）。
    # 健全な状態では外す。残すと check 10 が（正しく）warn して、「健全」の検査にならない
    rm "$h/.codex/agents/test-auditor.toml"
    HOME="$h" bash "$SETUP" install >/dev/null 2>&1
    make_trust_toml "$h/.codex/hooks.json" "$h/.codex/config.toml"
    echo "$h"
}

HV="$(make_verify_home ok)"
assert_eq "前提: verify 用の fixture の hooks.json に自前 hook が settings.json と同数ある（抽出が 0 件だと「1 本消した」を検出できないまま pass する）" "$SELF_COUNT" "$(self_hook_count "$HV/.codex/hooks.json")"
assert_eq "前提: 組み立てた信頼キーが自前 hook の数と一致する" "$SELF_COUNT" "$(grep -c '^\[hooks\.state\.' "$HV/.codex/config.toml")"

out="$(verify_run "$HV")"
rc_ok="$(cat "$WORK/verify.rc")"
sec8="$(verify_section "$out" 8)"; sec10="$(verify_section "$out" 10)"; sec11="$(verify_section "$out" 11)"; sec12="$(verify_section "$out" 12)"
assert_eq "健全な状態: verify は fail なしで終わる（衝突の review・grill は warn で fail にしない）" "0" "$rc_ok"
assert_eq "C-24 健全: check 8 に fail が無い" "0" "$(count_tag "$sec8" '[FAIL]')"
assert_contains "C-24 健全: 衝突した review を check 8 が warn で知らせる" "$sec8" "review"
assert_contains "C-24 健全: 他者のリンクに当たった grill を check 8 が warn で知らせる" "$sec8" "grill"
assert_eq "C-25 健全: check 10（TOML の同期）に warn・fail が無い" "0" "$(( $(count_tag "$sec10" '[WARN]') + $(count_tag "$sec10" '[FAIL]') ))"
assert_positive "C-25 健全: check 10 が実際に走った（見出しを切り出せている。空振りで通っていない）" "$(count_tag "$sec10" '[PASS]')"
assert_eq "C-26 健全: check 11（AGENTS.md）に warn・fail が無い" "0" "$(( $(count_tag "$sec11" '[WARN]') + $(count_tag "$sec11" '[FAIL]') ))"
assert_positive "C-26 健全: check 11 が実際に走った" "$(count_tag "$sec11" '[PASS]')"
assert_eq "C-27 健全: check 12（hooks.json の位置と信頼）に warn・fail が無い" "0" "$(( $(count_tag "$sec12" '[WARN]') + $(count_tag "$sec12" '[FAIL]') ))"
assert_positive "C-27 健全: check 12 が実際に走った" "$(count_tag "$sec12" '[PASS]')"

# --- C-8: 実物の判定役 test-auditor の TOML は read-only で、preload の指示を持つ ---
# 35 件の集計に埋もれると、判定役が書き込める agent で動く（read-only の取り違え）・基準なしで判定する回帰を見逃す
ta_toml="$HV/.codex/agents/test-auditor.toml"
assert_eq "C-8 実物の test-auditor.toml は sandbox_mode = read-only" "1" "$(grep -c -F 'sandbox_mode = "read-only"' "$ta_toml")"
assert_contains "C-8 実物の test-auditor.toml の本文の先頭で test-audit の SKILL.md を読ませる" \
    "$(grep '^developer_instructions = ' "$ta_toml")" "~/.agents/skills/test-audit/SKILL.md を読む"

# --- C-25: TOML を 1 件古くする → check 10 だけが warn ---
HT="$(make_verify_home toml)"
printf '%s\n' '# edited by hand' >>"$HT/.codex/agents/ad-security-reviewer.toml"
out="$(verify_run "$HT")"
assert_eq "C-25 TOML を 1 件古くすると check 10 が warn を 1 件にまとめて出す" "1" "$(count_tag "$(verify_section "$out" 10)" '[WARN]')"
assert_contains "C-25 warn は ./setup.sh install を案内する（install 待ちの扱い）" "$(verify_section "$out" 10)" "./setup.sh install"
assert_eq "C-25 他の Codex check（11・12）は増えない" "0" "$(( $(count_tag "$(verify_section "$out" 11)" '[WARN]') + $(count_tag "$(verify_section "$out" 12)" '[WARN]') ))"
assert_eq "C-25 TOML のずれは fail にしない" "0" "$(cat "$WORK/verify.rc")"

HT2="$(make_verify_home toml2)"
printf '%s\n' '# edited by hand' >>"$HT2/.codex/agents/ad-security-reviewer.toml"
rm "$HT2/.codex/agents/api-designer.toml"
out="$(verify_run "$HT2")"
assert_eq "C-25 古い TOML が複数（差分 1 件・未配置 1 件）でも、check 10 は warn を 1 件にまとめる（件数分は出さない）" "1" "$(count_tag "$(verify_section "$out" 10)" '[WARN]')"
assert_contains "C-25 まとめた warn が件数（2 件）を示す" "$(verify_section "$out" 10)" "2 件"

# --- C-26: ブロックを消す・ブロックの中身が古い → check 11 が warn（サイズの上限は下の境界のテスト）---
HB2="$(make_verify_home block)"
awk -v b='<!-- BEGIN gamonges-prompt: codex 読み替え表 -->' -v e='<!-- END gamonges-prompt: codex 読み替え表 -->' '$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }' \
    "$HB2/.codex/AGENTS.md" >"$WORK/agents-noblock.md" && cp "$WORK/agents-noblock.md" "$HB2/.codex/AGENTS.md"
out="$(verify_run "$HB2")"
assert_eq "C-26 読み替え表のブロックを消すと check 11 が warn" "1" "$(count_tag "$(verify_section "$out" 11)" '[WARN]')"

# ブロックの中身が古い（取り込み機能が上書きした・install 待ち）。ブロックは在るので、見出しの有無だけでは検知できない
HBS="$(make_verify_home stale-block)"
perl -i -0pe 's/(<!-- BEGIN gamonges-prompt: skills 共通規約 -->\n)/$1(stale line injected by something else)\n/' "$HBS/.codex/AGENTS.md"
assert_eq "前提: 共通規約ブロックに 1 行足した（見出しは残っている）" "1" "$(grep -c -F 'stale line injected' "$HBS/.codex/AGENTS.md")"
out="$(verify_run "$HBS")"
assert_eq "C-26 ブロックの中身が古いと check 11 が warn（見出しが在るだけでは通さない）" "1" "$(count_tag "$(verify_section "$out" 11)" '[WARN]')"
assert_contains "C-26 warn は中身が一致しないブロックを名指しする" "$(verify_section "$out" 11)" "共通規約"


# --- C-27 (a): hooks.json から 1 本消す / 自前グループを末尾へ移す → check 12 が warn ---
HH1="$(make_verify_home hook1)"
jq '.hooks.UserPromptSubmit[0].hooks |= map(select(.command | contains("hook-detect-correction.sh") | not))' \
    "$HH1/.codex/hooks.json" >"$WORK/hh1.json" && cp "$WORK/hh1.json" "$HH1/.codex/hooks.json"
assert_eq "前提: 1 本消した fixture の自前 hook は 1 本少ない" "$((SELF_COUNT - 1))" "$(self_hook_count "$HH1/.codex/hooks.json")"
out="$(verify_run "$HH1")"
assert_positive "C-27(a) 自前 hook を 1 本消すと check 12 が warn を出す" "$(count_tag "$(verify_section "$out" 12)" '[WARN]')"
assert_contains "C-27(a) warn は消えたイベントを名指しする" "$(verify_section "$out" 12)" "UserPromptSubmit"

HH2="$(make_verify_home hook2)"
jq '.hooks.PreToolUse |= (.[2:] + .[0:2])' "$HH2/.codex/hooks.json" >"$WORK/hh2.json" && cp "$WORK/hh2.json" "$HH2/.codex/hooks.json"
assert_eq "前提: 自前グループを末尾へ移した fixture も自前 hook は全件（消していないので件数では分からない）" "$SELF_COUNT" "$(self_hook_count "$HH2/.codex/hooks.json")"
out="$(verify_run "$HH2")"
assert_positive "C-27(a) 自前グループを末尾へ移すと（位置がずれて信頼が外れる）check 12 が warn を出す" "$(count_tag "$(verify_section "$out" 12)" '[WARN]')"
assert_contains "C-27(a) warn は PreToolUse を名指しする" "$(verify_section "$out" 12)" "PreToolUse"

# --- C-27 (b): 信頼キーの欠落。1 件だけ消すと、その 1 件だけが warn になる（全件を「存在」と判定する方向の誤りも捕まえる）---
HK="$(make_verify_home key)"
# [hooks.state."…"] の直後の trusted_hash 行も消す（見出しだけを消すと孤立した行が残る）
awk '/:user_prompt_submit:0:1"\]/ { getline; next } { print }' "$HK/.codex/config.toml" >"$WORK/cfg-missing.toml"
cp "$WORK/cfg-missing.toml" "$HK/.codex/config.toml"
assert_eq "前提: 1 件消した config.toml の信頼キーは 1 件少ない" "$((SELF_COUNT - 1))" "$(grep -c '^\[hooks\.state\.' "$HK/.codex/config.toml")"
out="$(verify_run "$HK")"
sec12="$(verify_section "$out" 12)"
assert_eq "C-27(b) 信頼キーを 1 件消すと、その 1 件だけが warn になる" "1" "$(count_tag "$sec12" '[WARN]')"
assert_contains "C-27(b) warn の文面に UserPromptSubmit が出る" "$sec12" "UserPromptSubmit"
assert_contains "C-27(b) warn の文面にグループと hook の位置 0:1 が出る" "$sec12" "0:1"
assert_contains "C-27(b) warn は /hooks で信頼し直すことを案内する" "$sec12" "/hooks"

# --- C-24: ~/.agents/skills/<name> が別 worktree 相当を指す（自分のリンク）→ fail / 無関係なパス → warn ---
HW="$(make_verify_home worktree)"
rm "$HW/.agents/skills/ask" && ln -s "$WORK/other-wt3/shared/skills/ask/" "$HW/.agents/skills/ask"
out="$(verify_run "$HW")"
sec8="$(verify_section "$out" 8)"
assert_eq "C-24 自分のリンクだが今のチェックアウトを指していない skill があると check 8 が fail" "1" "$(count_tag "$sec8" '[FAIL]')"
assert_contains "C-24 fail は該当の skill（ask）を名指しする" "$sec8" "ask"
assert_eq "C-24 fail があれば verify は exit 1" "1" "$(cat "$WORK/verify.rc")"

HW2="$(make_verify_home worktree-old)"
rm "$HW2/.agents/skills/design" && ln -s "$WORK/other-wt3/claude/skills/design/" "$HW2/.agents/skills/design"
out="$(verify_run "$HW2")"
assert_eq "C-24 旧 claude/skills を指す自分のリンクも、今のチェックアウトを指していなければ check 8 が fail" "1" "$(count_tag "$(verify_section "$out" 8)" '[FAIL]')"
assert_contains "C-24 fail は該当の skill（design）を名指しする" "$(verify_section "$out" 8)" "design"

# --- ~/.codex が無い HOME では Codex の check を飛ばす（INFO）---
HX="$(new_home v-nocodex)"
HOME="$HX" bash "$SETUP" install >/dev/null 2>&1
out="$(verify_run "$HX")"
for n in 8 10 11 12; do
    assert_contains "~/.codex が無いと check ${n} は省略される" "$(verify_section "$out" "$n")" "省略"
done
assert_eq "~/.codex が無くても verify は Codex のために fail しない" "0" "$(cat "$WORK/verify.rc")"

# --- C-28 / 7(1): decide_ask_or_deny の対称性。repo の複製（mini repo）の hook を壊して見る ---
make_mini_repo() {  # $1=名前 → mini repo のパス（verify はスクリプトの所在から repo ルートを導く）
    local d="$WORK/mini-$1"
    mkdir -p "$d/shared/scripts" "$d/claude" "$d/codex"
    cp "$SETUP" "$d/setup.sh"
    cp "$REPO_SHARED"/scripts/*.sh "$REPO_SHARED"/scripts/*.py "$d/shared/scripts/"
    ln -s "$REPO_SHARED/skills" "$d/shared/skills"
    ln -s "$REPO_SHARED/agents" "$d/shared/agents"
    cp "$REPO_SHARED/global-rules.md" "$d/shared/"
    cp "$REPO_ROOT/claude/settings.json" "$d/claude/"
    cp "$REPO_ROOT"/codex/* "$d/codex/"
    echo "$d"
}
HM1="$(new_home v-sym-ok)"
MINI="$(make_mini_repo ok)"
out="$(verify_run "$HM1" "$MINI/shared/scripts/verify-skills.sh")"
sec7="$(verify_section "$out" '7(1)')"
assert_positive "C-28 健全: check 7(1) が実際に走った（見出しを切り出せている）" "$(count_tag "$sec7" '[PASS]')"
assert_eq "C-28 健全: check 7(1) に warn が無い（ask を返す 4 本すべてに decide_ask_or_deny があり、直書きの ask が無い）" "0" "$(count_tag "$sec7" '[WARN]')"

# 「自分のリンク」の判定パターンが setup.sh と verify で食い違う（片方だけ直した）
MINI4="$(make_mini_repo pattern)"
perl -i -pe 's#\*/claude/skills/"\$2"\|\*/claude/skills/"\$2"/\)#*/claude/skills/"\$2"|*/other/skills/"\$2"/)#' "$MINI4/setup.sh"
assert_eq "前提: mini repo の setup.sh のパターンを書き換えられた" "1" "$(grep -c -F '*/other/skills/' "$MINI4/setup.sh")"
out="$(verify_run "$HM1" "$MINI4/shared/scripts/verify-skills.sh")"
assert_contains "C-28 「自分のリンク」の判定パターンの食い違いを check 7(1) が warn" "$(verify_section "$out" '7(1)')" "判定パターン"

MINI2="$(make_mini_repo nofunc)"
perl -i -0pe 's/decide_ask_or_deny\(\)/decide_removed()/' "$MINI2/shared/scripts/hook-confirm-destructive-git.sh"
out="$(verify_run "$HM1" "$MINI2/shared/scripts/verify-skills.sh")"
assert_contains "C-28 ask を返す hook から decide_ask_or_deny が消えると check 7(1) が warn（hook 名を名指し）" "$(verify_section "$out" '7(1)')" "hook-confirm-destructive-git.sh"

MINI3="$(make_mini_repo literal)"
printf '%s\n' '' '# 5 本目の hook が ask を直書きした（Codex では確認が出ず、ガードが黙って開く）' \
    'echo '"'"'{"hookSpecificOutput":{"permissionDecision": "ask"}}'"'" >>"$MINI3/shared/scripts/hook-block-full-lint.sh"
out="$(verify_run "$HM1" "$MINI3/shared/scripts/verify-skills.sh")"
assert_contains "C-28 decide_ask_or_deny を通らない ask の直書きは check 7(1) が warn（hook 名を名指し）" "$(verify_section "$out" '7(1)')" "hook-block-full-lint.sh"

# --- C-26: 上限 32 KiB は「~/.codex/AGENTS.md と repo 直下の AGENTS.md の合計」---
# 片方だけを見る実装や、境界値（32767 / 32768）の取り違えを捕まえるため、repo 直下の AGENTS.md の大きさを
# mini repo で固定する。~/.codex/AGENTS.md 単体は上限未満のまま、合計だけが境界をまたぐ
HSZ="$(make_verify_home size)"
codex_md_bytes="$(wc -c <"$HSZ/.codex/AGENTS.md" | tr -d ' ')"
assert_positive "前提: ~/.codex/AGENTS.md の大きさを取れている" "$codex_md_bytes"
assert_eq "前提: ~/.codex/AGENTS.md 単体は 32768 バイト未満（合計を見ない実装では warn が出ない大きさ）" "1" "$([[ "$codex_md_bytes" -lt 32768 ]] && echo 1 || echo 0)"
for total in 32767 32768; do
    MINI_SZ="$(make_mini_repo "size-$total")"
    head -c $((total - codex_md_bytes)) /dev/zero | tr '\0' 'x' >"$MINI_SZ/AGENTS.md"
    out="$(verify_run "$HSZ" "$MINI_SZ/shared/scripts/verify-skills.sh")"
    if [[ "$total" -eq 32767 ]]; then
        assert_eq "C-26 合計が 32767 バイト（上限未満）なら check 11 は warn を出さない" "0" "$(count_tag "$(verify_section "$out" 11)" '[WARN]')"
    else
        assert_eq "C-26 合計が 32768 バイト（上限に達する）なら check 11 が warn を 1 件出す" "1" "$(count_tag "$(verify_section "$out" 11)" '[WARN]')"
        assert_contains "C-26 その warn は Codex の指示の上限（project_doc_max_bytes）を名指しする" "$(verify_section "$out" 11)" "project_doc_max_bytes"
    fi
done

# --- C-8: agents の TOML 生成に失敗したら、何も書かず、既存の生成物も消さない ---
# 生成が失敗すると出力ディレクトリは空になる。失敗を無視して後続の orphan 削除に進むと、
# 「全件が生成元に無い」と読んで、置いてある生成物を全件消す
GF="$WORK/genfail"
mkdir -p "$GF/shared/skills/demo" "$GF/shared/agents/x" "$GF/claude" "$GF/codex"
cp "$SETUP" "$GF/setup.sh"
cp "$REPO_ROOT/codex/gen-agents.py" "$REPO_ROOT/codex/codex-rules.md" "$GF/codex/"
printf '%s\n' '---' 'name: demo' 'description: demo' '---' >"$GF/shared/skills/demo/SKILL.md"
printf '%s\n' '{}' >"$GF/claude/settings.json"
: >"$GF/shared/global-rules.md"
printf '%s\n' '---' 'name: bad' 'description: has an unknown key' 'color: red' '---' 'Body.' >"$GF/shared/agents/x/bad.md"
HG="$(new_home genfail)"
mkdir -p "$HG/.codex/agents"
printf '%s\n' '# generated-by: gamonges-prompt setup.sh — source: shared/agents/x/old.md — 手で編集しない' 'name = "old"' >"$HG/.codex/agents/old.toml"
SETUP_REAL="$SETUP"
SETUP="$GF/setup.sh"
run_setup "$HG" install
SETUP="$SETUP_REAL"
assert_eq "C-8 生成に失敗する agent があると install は exit 非 0" "1" "$([[ "$(last_rc)" != "0" ]] && echo 1 || echo 0)"
assert_contains "C-8 失敗の理由（未知の frontmatter キー）を出す" "$(last_out)" "未知の frontmatter キー"
assert_contains "C-8 何も書き込んでいないことを出す" "$(last_out)" "何も書き込んでいません"
assert_eq "C-8 生成に失敗しても、既存の生成物（old.toml）を消さない" "yes" "$([[ -f "$HG/.codex/agents/old.toml" ]] && echo yes || echo no)"
# bad.toml の不在だけでは、別名の新規ファイルや .new.<PID> の残骸を捕まえられない。配置先の中身そのものを固定する
assert_eq "C-8 生成に失敗したら、配置先に新しいファイル（別名・一時ファイルの残骸を含む）を作らない" "old.toml" \
    "$(find "$HG/.codex/agents" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort | tr '\n' ' ' | sed 's/ $//')"

echo ""
echo "$pass_count passed / $fail_count failed"
[[ "$fail_count" -eq 0 ]]
