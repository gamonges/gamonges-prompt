#!/usr/bin/env bash
# worktree 同期の hook（shared/scripts/sync-claude-to-worktree.sh）の挙動テスト。
#
# 守りたいのは「追跡ファイルは worktree のブランチが正なので触らない」「メインにしか無い未追跡の
# 設定だけを、worktree にあるものを上書きせずに運ぶ」。壊れても hook は exit 0 で終わり、追跡
# ファイルが古い版に戻るだけなので、通常の動作確認では気づけない。
#
# 偽の repo を作って linked worktree を足し、実際の hook の入口と同じく worktree のルートを cwd に
# してスクリプトを流す。HOME は偽のディレクトリにし、sync-cursor-skills.sh は呼ばれたら記録
# ファイルに 1 行書くだけの偽物に差し替える（git・rsync は /usr/bin で mise の shim ではないので、
# HOME を替えても壊れない）。
#
# 起動: bash shared/scripts/tests/test-sync-claude-to-worktree.sh

# set -e は使わない。1 件目の失敗で残りが走らなくなると、Red で全件の失敗を確かめられない
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# install 済みのコピー（~/.claude/scripts/）ではなく repo の版を流す
SUT="$REPO_ROOT/shared/scripts/sync-claude-to-worktree.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass_count=0
fail_count=0

pass() { echo -e "${GREEN}[PASS]${NC} $1"; pass_count=$((pass_count + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; fail_count=$((fail_count + 1)); }

# macOS の /var は /private/var への symlink。スクリプトは pwd -P と git worktree list を比べるので、
# symlink のままだとガードで抜けて、何も検証せずに Green になる
BASE="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() { rm -rf "$BASE"; }
trap cleanup EXIT

# 偽の HOME では ~/.gitconfig が読まれないので、コミットに要る名前をここで与える。利用者の
# global・system の設定（署名・hooksPath 等）が前提データの作成に混ざらないようにもする
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset XDG_CONFIG_HOME

# ============================================================ 共通の道具

assert_eq() {  # $1=名前 $2=期待 $3=実際
    if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1（期待「$2」、実際「$3」）"; fi
}

assert_has() {  # $1=名前 $2=出力 $3=含むべき文字列
    if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1（「$3」が無い）: ${2:0:400}"; fi
}

assert_not_has() {  # $1=名前 $2=出力 $3=含まないはずの文字列
    if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1（「$3」がある）: ${2:0:400}"; fi
}

assert_exists() {  # $1=名前 $2=パス
    if [[ -e "$2" || -L "$2" ]]; then pass "$1"; else fail "$1（$2 が無い）"; fi
}

assert_absent() {  # $1=名前 $2=パス
    if [[ ! -e "$2" && ! -L "$2" ]]; then pass "$1"; else fail "$1（$2 がある）"; fi
}

assert_content() {  # $1=名前 $2=パス $3=期待の中身
    local got
    got="$(cat "$2" 2>/dev/null || echo '<読めない>')"
    assert_eq "$1" "$3" "$got"
}

# ケースごとに、メインの repo・偽の HOME・呼び出しの記録を作り直す（前のケースの残りで判定が狂わないように）
#   MAIN=メインの worktree  WT=linked worktree（作るのは add_worktree）  CASE_HOME=偽の HOME  CALLS=記録
new_case() {  # $1=ケース名
    local d="$BASE/$1"
    MAIN="$d/main"; WT="$d/wt"; CASE_HOME="$d/home"; CALLS="$d/calls.log"; OUT_DIR="$d"
    mkdir -p "$MAIN" "$CASE_HOME/.claude/scripts"
    git init -q -b main "$MAIN"
    echo readme > "$MAIN/README.md"
    : > "$CALLS"
    printf '#!/bin/bash\necho called >> %q\n' "$CALLS" > "$CASE_HOME/.claude/scripts/sync-cursor-skills.sh"
    chmod +x "$CASE_HOME/.claude/scripts/sync-cursor-skills.sh"
}

put() {  # $1=ファイル $2=中身。親ディレクトリも作る
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "$2" > "$1"
}

commit() {  # $1=worktree $2..=コミットするパス（一括の add は使わず、対象を明示する）
    local wt="$1"; shift
    git -C "$wt" add -- "$@" && git -C "$wt" commit -q -m "fixture"
}

add_worktree() {  # メインの HEAD から branch を切って linked worktree を作る
    git -C "$MAIN" worktree add -q -b feat "$WT"
}

# hook と同じく指定のディレクトリを cwd にして流す。RC・ERR・CALL_COUNT を返す
run_sync() {  # $1=cwd
    : > "$CALLS"  # 1 ケースで 2 回流すとき、前の回の呼び出しを数えないように
    # hook は shebang の /bin/bash（macOS では 3.2）で動くので、PATH の bash ではなくそれで流す
    ( cd "$1" && HOME="$CASE_HOME" /bin/bash "$SUT" </dev/null ) >"$OUT_DIR/out" 2>"$OUT_DIR/err"
    RC=$?
    ERR="$(cat "$OUT_DIR/err")"
    CALL_COUNT="$(wc -l < "$CALLS" | tr -d ' ')"
}

# ブランチで変えた版は、メインの版とサイズを変える。同じサイズで同じ秒に書くと、rsync の quick check
# （サイズと mtime）が同じファイルとみなして写さず、直す前の版でも通ってしまう
NEW_ON_BRANCH="changed-on-branch"

# ============================================================ C1: 追跡ファイルはブランチの版のまま
# regression: 直す前は .claude/ を丸ごと rsync していたので、メインの checkout が古いと、
# ブランチで変えた追跡ファイルがメインの古い版に戻り、git status に M が出た
echo "== C1: 両方で追跡しているファイルをブランチで変えた（regression）"
new_case c1
put "$MAIN/.claude/rules/a.md" old
commit "$MAIN" README.md .claude/rules/a.md
add_worktree
put "$WT/.claude/rules/a.md" "$NEW_ON_BRANCH"
commit "$WT" .claude/rules/a.md
run_sync "$WT"
assert_eq "C1 exit 0" 0 "$RC"
assert_content "C1 追跡ファイルがブランチの版のまま" "$WT/.claude/rules/a.md" "$NEW_ON_BRANCH"
assert_eq "C1 git status に変更が出ない" "" "$(git -C "$WT" status --porcelain -- .claude/rules/a.md)"

# ============================================================ C2: 未追跡で ignore されていない設定は運ぶ
# .claude/CLAUDE.md だけをローカルに置く repo の形。ディレクトリへの相対 symlink（.cursor/skills への
# リンク）も symlink のまま運ぶ
echo "== C2: メインだけにある未追跡（ignore されていない）の設定"
new_case c2
put "$MAIN/.cursor/skills/x/SKILL.md" skill
commit "$MAIN" README.md .cursor/skills/x/SKILL.md
add_worktree
put "$MAIN/.claude/CLAUDE.md" local
mkdir -p "$MAIN/.claude/skills"
ln -s ../../.cursor/skills/x "$MAIN/.claude/skills/x"
run_sync "$WT"
assert_eq "C2 exit 0" 0 "$RC"
assert_content "C2 CLAUDE.md がコピーされる" "$WT/.claude/CLAUDE.md" local
assert_eq "C2 ディレクトリへの symlink は symlink のまま" "../../.cursor/skills/x" "$(readlink "$WT/.claude/skills/x" 2>/dev/null)"
assert_has "C2 Synced を stderr に出す" "$ERR" "Synced"

# ============================================================ C3: gitignore 対象の設定も運ぶ
echo "== C3: メインだけにある gitignore 対象の設定"
new_case c3
put "$MAIN/.gitignore" ".claude/CLAUDE.md"
commit "$MAIN" README.md .gitignore
add_worktree
put "$MAIN/.claude/CLAUDE.md" ignored-local
run_sync "$WT"
assert_eq "C3 exit 0" 0 "$RC"
assert_content "C3 ignore 対象の CLAUDE.md もコピーされる" "$WT/.claude/CLAUDE.md" ignored-local

# ============================================================ C4: worktrees/ と settings.local.json は運ばない
echo "== C4: 除外の対象"
new_case c4
commit "$MAIN" README.md
add_worktree
put "$MAIN/.claude/worktrees/x/f" nested
put "$MAIN/.claude/settings.local.json" '{}'
put "$MAIN/.claude/sub/settings.local.json" '{}'
put "$MAIN/.claude/keep.md" keep
run_sync "$WT"
assert_eq "C4 exit 0" 0 "$RC"
assert_absent "C4 .claude/worktrees/ 配下を写さない" "$WT/.claude/worktrees"
assert_absent "C4 直下の settings.local.json を写さない" "$WT/.claude/settings.local.json"
assert_absent "C4 深い settings.local.json も写さない" "$WT/.claude/sub/settings.local.json"
assert_content "C4 除外の対象でないものは写す" "$WT/.claude/keep.md" keep

# ============================================================ C5: worktree にあるものは上書きしない
# regression: メインでは未追跡でも、ブランチで足して追跡しているファイルは worktree の版が正。
# 直す前はメインの未追跡の版で上書きした
echo "== C5: メインで未追跡・ブランチで追跡（regression）"
new_case c5
commit "$MAIN" README.md
add_worktree
put "$WT/.claude/b.md" branch
commit "$WT" .claude/b.md
put "$MAIN/.claude/b.md" main-local
run_sync "$WT"
assert_eq "C5 exit 0" 0 "$RC"
assert_content "C5 worktree の版のまま" "$WT/.claude/b.md" branch
assert_eq "C5 git status に変更が出ない" "" "$(git -C "$WT" status --porcelain -- .claude/b.md)"

# ============================================================ C6: 未追跡 0 件なら何もしない
# regression: .claude/ を全部追跡していて未追跡が 0 件の形。直す前は毎回丸ごと写して Synced を出した
echo "== C6: 全部追跡で未追跡 0 件の形（regression）"
new_case c6
put "$MAIN/.claude/rules/a.md" old
put "$MAIN/.claude/skills/s/SKILL.md" s1
commit "$MAIN" README.md .claude/rules/a.md .claude/skills/s/SKILL.md
add_worktree
put "$WT/.claude/rules/a.md" "$NEW_ON_BRANCH"
commit "$WT" .claude/rules/a.md
run_sync "$WT"
assert_eq "C6 exit 0" 0 "$RC"
assert_eq "C6 git status がきれい" "" "$(git -C "$WT" status --porcelain)"
assert_not_has "C6 Synced を出さない" "$ERR" "Synced"

# ============================================================ C7: 実行場所のガード
echo "== C7: メインのルート・linked worktree のサブディレクトリでは何もしない"
new_case c7
put "$MAIN/.cursor/skills/x/SKILL.md" skill
put "$MAIN/sub/keep" keep
commit "$MAIN" README.md .cursor/skills/x/SKILL.md sub/keep
add_worktree
# CLAUDE.md は置かない。置くとメインのルートでは手前の早期 return で抜け、ガードを外しても通ってしまう
put "$MAIN/.claude/other.md" other
run_sync "$MAIN"
assert_eq "C7 メイン: exit 0" 0 "$RC"
assert_not_has "C7 メイン: Synced を出さない" "$ERR" "Synced"
assert_eq "C7 メイン: sync-cursor-skills を呼ばない" 0 "$CALL_COUNT"
run_sync "$WT/sub"
assert_eq "C7 サブディレクトリ: exit 0" 0 "$RC"
assert_absent "C7 サブディレクトリに .claude を作らない" "$WT/sub/.claude"
assert_eq "C7 サブディレクトリ: sync-cursor-skills を呼ばない" 0 "$CALL_COUNT"

# ============================================================ C8: 写す物が無くても sync-cursor-skills は呼ぶ
# .cursor/skills/ だけを持つ形。リンクを作るのは worktree の .cursor/skills/ が在るかで決まり、
# 写したかどうかとは関係が無い
echo "== C8: 未追跡が除外の対象だけ・.cursor/skills/ がある"
new_case c8
put "$MAIN/.cursor/skills/x/SKILL.md" skill
commit "$MAIN" README.md .cursor/skills/x/SKILL.md
add_worktree
put "$MAIN/.claude/settings.local.json" '{}'
run_sync "$WT"
assert_eq "C8 exit 0" 0 "$RC"
assert_absent "C8 何も写さない" "$WT/.claude/settings.local.json"
assert_not_has "C8 Synced を出さない" "$ERR" "Synced"
assert_eq "C8 sync-cursor-skills を 1 回呼ぶ" 1 "$CALL_COUNT"

# ============================================================ C9: 非 ASCII・空白を含む名前
# git は非 ASCII のパスを既定で "\343..." と引用する。引用されたパスは --files-from で存在しない
# パスになり、黙って写らない（core.quotePath=false を守るのは日本語の名前のほう）。空白は git が引用しない
# ので quotePath の証明にはならず、openrsync の --files-from が空白を含むパスを扱えることの確認として置く
echo "== C9: 日本語・空白を含むファイル名"
new_case c9
commit "$MAIN" README.md
add_worktree
put "$MAIN/.claude/メモ.md" memo
put "$MAIN/.claude/rules/with space.md" space
run_sync "$WT"
assert_eq "C9 exit 0" 0 "$RC"
assert_content "C9 日本語の名前のファイルを写す" "$WT/.claude/メモ.md" memo
assert_content "C9 空白を含む名前のファイルを写す" "$WT/.claude/rules/with space.md" space
assert_eq "C9 .cursor/skills/ が無ければ sync-cursor-skills を呼ばない" 0 "$CALL_COUNT"

# ============================================================ C10: 引用が残るパスは飛ばす
# タブ・改行・" ・\ を含むパスは core.quotePath=false でも引用が残る。対象外として 1 行知らせ、
# 他のファイルは写す
echo "== C10: 引用が残るパス（タブを含む名前）"
new_case c10
commit "$MAIN" README.md
add_worktree
put "$MAIN/.claude/a	b.md" tab
put "$MAIN/.claude/ok.md" ok
run_sync "$WT"
assert_eq "C10 exit 0" 0 "$RC"
assert_absent "C10 引用が残るパスは写さない" "$WT/.claude/a	b.md"
assert_content "C10 他のファイルは写す" "$WT/.claude/ok.md" ok
assert_eq "C10 飛ばしたことを stderr に 1 行出す" 1 "$(grep -c '対象外' "$OUT_DIR/err")"

# ============================================================ C11: 同期済みなら何もしない
# worktree に .claude/CLAUDE.md があれば、前のプロンプトで同期済みとみなして速く抜ける
echo "== C11: worktree に .claude/CLAUDE.md が既にある"
new_case c11
put "$MAIN/.cursor/skills/x/SKILL.md" skill
commit "$MAIN" README.md .cursor/skills/x/SKILL.md
add_worktree
put "$WT/.claude/CLAUDE.md" already
put "$MAIN/.claude/other.md" other
run_sync "$WT"
assert_eq "C11 exit 0" 0 "$RC"
assert_absent "C11 何も写さない" "$WT/.claude/other.md"
assert_content "C11 既存の CLAUDE.md はそのまま" "$WT/.claude/CLAUDE.md" already
assert_eq "C11 sync-cursor-skills を呼ばない" 0 "$CALL_COUNT"

# ============================================================ まとめ
echo ""
echo "PASS: $pass_count  FAIL: $fail_count"
[[ "$fail_count" -eq 0 ]]
