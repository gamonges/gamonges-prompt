#!/usr/bin/env bash
# series-run の横断の受信箱（shared/skills/series-run/scripts/series_inbox.py）の挙動テスト。
#
# 受信箱は 3 つの coordinator の状態ファイルから作る読む専用の写しで、壊れても監督は止まらない。
# 守りたいのは「待っているものを落とさない」「古い状態でビューを巻き戻さない」「書きかけを見せない」で、
# どれも壊れたまま気づけない（ビューが少し古い・少し欠けるだけに見える）。
#
# 置き場所は SERIES_RUN_STATE_DIR で一時ディレクトリに向ける。HOME は差し替えない（mise の shim が壊れるため）。
# スクリプトは /usr/bin/python3（3.9）でも動かす前提なので、python3 と /usr/bin/python3 が別物なら両方で回す。
#
# 起動: bash shared/scripts/tests/test-series-inbox.sh

# set -e は使わない。1 件目の失敗で残りが走らなくなると、Red で全件の失敗を確かめられない
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INBOX="$REPO_ROOT/shared/skills/series-run/scripts/series_inbox.py"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass_count=0
fail_count=0
LABEL=""

pass() { echo -e "${GREEN}[PASS]${NC} ${LABEL}$1"; pass_count=$((pass_count + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} ${LABEL}$1"; fail_count=$((fail_count + 1)); }

BASE="$(mktemp -d)"
cleanup() { rm -rf "$BASE"; }
trap cleanup EXIT

assert_rc() {  # $1=名前 $2=期待 $3=実際 $4=出力（失敗時に見せる）
    if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1（rc=$3、期待 $2）: ${4:0:400}"; fi
}
assert_has() {  # $1=名前 $2=出力 $3=含むべき文字列
    if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1（「$3」が無い）: ${2:0:400}"; fi
}
assert_not_has() {  # $1=名前 $2=出力 $3=含まないはずの文字列
    if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1（「$3」がある）"; fi
}
assert_eq() {  # $1=名前 $2=期待 $3=実際
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1（期待「$2」、実際「$3」）"; fi
}

ib() { SERIES_RUN_STATE_DIR="$DIR" "$PY" "$INBOX" "$@"; }

# 状態ファイル（state-format.md の書式）。$1=パス $2=待っているものの本文 $3=作業単位の表の行 $4=答えが出たものの本文
write_state() {
    mkdir -p "$(dirname "$1")"
    cat >"$1" <<EOF
---
type: Series Run
series: /abs/series.md
adapter: orca
timestamp: 2026-10-29T10:00:00+09:00
---

## 作業単位

| worktree | 担当の段 | 工程の現在地 | 待っている相手 | 次 |
|----------|---------|-------------|--------------|----|
$3

## 運用の約束

例のブロック（囲みの中の見出しは節として読まない）:

\`\`\`markdown
## ユーザー向け: 質問と回答の一覧

### 待っているもの

- FENCED-FAKE の問い
\`\`\`

## ユーザー向け: 質問と回答の一覧

### 待っているもの

$2

### 答えが出たもの

$4
EOF
}

run_tests() {
    DIR="$WORK/state"
    local wa="$WORK/wt-a" wb="$WORK/wt-b" sa="$WORK/a/tmp/series-run.md" sb="$WORK/b/tmp/series-run.md"
    mkdir -p "$wa/tmp" "$wb/tmp"
    printf '<html></html>\n' >"$wa/tmp/meaning-card.html"
    write_state "$sa" "- Q-1（be1）: 仕様の値を 30 日にするか。推奨: 30 日。PR https://github.com/o/r/pull/7" \
        "| $wa | be1 | checks: 確認中 | なし | review |
| $wb | fe1 | ユーザーの操作待ち（/create-pr） | ユーザー | checks |" \
        "- Q-3（be1）: 命名をそろえる — 推奨で進めた（2026-10-29）。覆すなら Q-3 で答える
- Q-2（fe1）: 回答済み — OK"
    write_state "$sb" "" "| $wb | api | review: 作業中 | worker | recheck |" ""

    # --- register: 1 シリーズ 1 ファイル。同じ状態ファイルの 2 回目は上書き ---
    out="$(ib register --state "$sa" --terminal term_old --title "注文の取込" 2>&1)"; rc=$?
    assert_rc "IB-1 register は exit 0" 0 "$rc" "$out"
    ib register --state "$sa" --terminal term_new --title "注文の取込" >/dev/null 2>&1
    assert_eq "IB-1 同じ状態ファイルの 2 回目は重複させない" 1 "$(ls "$DIR/registry" | wc -l | tr -d ' ')"
    ib register --state "$sb" --terminal term_b --title "請求の出力" >/dev/null 2>&1
    assert_eq "IB-1 別の状態ファイルは別のファイル" 2 "$(ls "$DIR/registry" | wc -l | tr -d ' ')"

    # --- render: 出力先を 1 行で返す ---
    out="$(ib render 2>&1)"; rc=$?
    assert_rc "IB-2 render は exit 0" 0 "$rc" "$out"
    assert_eq "IB-2 標準出力は出力先のパス 1 行" "$DIR/inbox.html" "$out"
    view="$(cat "$DIR/inbox.html" 2>/dev/null)"
    assert_has "IB-2 待っているもの（Q-1）が出る" "$view" "Q-1（be1）: 仕様の値を 30 日にするか"
    assert_has "IB-2 シリーズの題名が出る" "$view" "注文の取込"
    assert_has "IB-2 答える terminal は register し直した新しい方" "$view" "term_new"
    assert_not_has "IB-2 古い terminal は出ない" "$view" "term_old"
    assert_has "IB-2 カードの HTML がある作業単位はリンクする" "$view" "href=\"file://$wa/tmp/meaning-card.html\""
    assert_not_has "IB-2 カードの HTML が無い作業単位はリンクしない" "$view" "$wb/tmp/meaning-card.html"
    assert_has "IB-2 作業単位の現在地が出る" "$view" "checks: 確認中"
    assert_has "IB-2 待っているものが無いシリーズは無いと出る" "$view" "待っているものは無い"
    assert_has "IB-2 推奨で進めたものに印を付ける" "$view" "<mark>- Q-3（be1）: 命名をそろえる — 推奨で進めた"
    assert_not_has "IB-2 回答済みのものは推奨で進めたものに入れない" "$view" "<mark>- Q-2"
    assert_not_has "IB-2 囲みの中の見出しを節として読まない" "$view" "FENCED-FAKE"
    assert_has "IB-2 開いたままのビューを追従させる" "$view" '<meta http-equiv="refresh" content="60">'
    # 外部に依存しない: URL はリンクの中にだけある
    bad="$(grep -E 'https?://' "$DIR/inbox.html" | grep -vc '<a href' || true)"
    assert_eq "IB-2 <a href の外に https?:// が無い" 0 "$bad"
    assert_has "IB-2 本文の URL はリンクにする" "$view" '<a href="https://github.com/o/r/pull/7">'

    # --- 終わったシリーズ: 状態ファイルが無い・全作業単位が 完了 か 対象外 ---
    local sc="$WORK/c/tmp/series-run.md" sd="$WORK/d/tmp/series-run.md"
    write_state "$sc" "" "| $wa | x1 | 完了 | なし | — |
| $wb | x2 | 対象外 | なし | 段が 2 つ以上 |" ""
    ib register --state "$sc" --terminal term_c --title "終わった題名" >/dev/null 2>&1
    ib register --state "$sd" --terminal term_d --title "消えた題名" >/dev/null 2>&1
    ib render >/dev/null 2>&1
    view="$(cat "$DIR/inbox.html")"
    done_lines="$(grep -c '終わった（登録が残っている）' "$DIR/inbox.html" || true)"
    assert_eq "IB-3 全部 完了・対象外 と 状態ファイルが無い の 2 つが「終わった」" 2 "$done_lines"
    assert_has "IB-3 状態ファイルが無いことを理由に書く" "$view" "状態ファイルが無い"

    # --- unregister: そのファイルだけ消す。無いものは exit 0 ---
    ib unregister --state "$sd" >/dev/null 2>&1; rc=$?
    assert_rc "IB-4 unregister は exit 0" 0 "$rc" ""
    assert_eq "IB-4 そのシリーズのファイルだけ消える" 3 "$(ls "$DIR/registry" | wc -l | tr -d ' ')"
    ib unregister --state "$sd" >/dev/null 2>&1; rc=$?
    assert_rc "IB-4 無いものの unregister も exit 0（冪等）" 0 "$rc" ""
    ib unregister --state "$sc" >/dev/null 2>&1

    # --- 書きかけを見せない: 壊れた状態ファイルで render が失敗しても、既存のビューが残る ---
    ib render >/dev/null 2>&1
    cp "$DIR/inbox.html" "$WORK/before.html"
    cp "$sb" "$WORK/sb.bak"
    printf '\xff\xfe broken\n' >"$sb"
    out="$(ib render 2>&1)"; rc=$?
    assert_rc "IB-5 壊れた状態ファイルの render は exit 1" 1 "$rc" "$out"
    if cmp -s "$WORK/before.html" "$DIR/inbox.html"; then pass "IB-5 失敗しても既存のビューが残る"; else fail "IB-5 失敗しても既存のビューが残る"; fi
    cp "$WORK/sb.bak" "$sb"
    # 置き換え（os.replace）で失敗させる。読み取りで失敗させると一時ファイルがそもそも作られず、後始末を検査しない
    local vd="$WORK/state-dirview"
    mkdir -p "$vd/inbox.html/x"
    out="$(SERIES_RUN_STATE_DIR="$vd" "$PY" "$INBOX" render 2>&1)"; rc=$?
    assert_rc "IB-5 置き換えに失敗した render は exit 1" 1 "$rc" "$out"
    assert_has "IB-5 失敗は理由の 1 行で返す（traceback にしない）" "$out" "series_inbox.py: render:"
    assert_eq "IB-5 置き換えに失敗しても一時ファイルを残さない" 0 "$(find "$vd" -name '.inbox-*' | wc -l | tr -d ' ')"
    # サブコマンドが無ければ usage を出して失敗する（何もせずに成功と返さない）
    out="$(ib 2>&1)"; rc=$?
    assert_rc "IB-5 サブコマンドが無ければ exit 1" 1 "$rc" "$out"
    assert_has "IB-5 サブコマンドが無ければ usage を出す" "$out" "usage:"

    # --- 巻き戻らない: 読み取りから置き換えまでを inbox.lock で囲む ---
    # 先にロックを取ってから render を起動し、読み取りの時間を置いてから状態を書き換え、ロックを外す。
    # render が読み取りをロックの外で行えば、書き換える前の状態（Q-1）でビューを作る
    mkdir -p "$DIR"
    "$PY" -c 'import fcntl,sys,time
f=open(sys.argv[1],"a"); fcntl.flock(f,fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(3)' \
        "$DIR/inbox.lock" "$WORK/locked" &
    local locker=$! tries=0
    # ロックを取れないまま待ち続けると Red が終わらないので、上限を置く（約 5 秒）
    while [[ ! -e "$WORK/locked" && $tries -lt 100 ]]; do "$PY" -c 'import time; time.sleep(0.05)'; tries=$((tries + 1)); done
    ib render >/dev/null 2>&1 &
    local renderer=$!
    "$PY" -c 'import time; time.sleep(1)'
    write_state "$sa" "- Q-9（be1）: 新しい問い" "| $wa | be1 | checks: 確認中 | なし | review |" ""
    wait "$locker"
    wait "$renderer"
    view="$(cat "$DIR/inbox.html")"
    assert_has "IB-6 ロックを待った render は新しい状態でビューを作る" "$view" "Q-9（be1）: 新しい問い"
    assert_not_has "IB-6 古い状態（Q-1）で巻き戻さない" "$view" "Q-1（be1）"
}

# python3 と /usr/bin/python3 が別物なら両方で全件を回す（3.9 で動くことの検証）
PYS=(python3)
if [[ -x /usr/bin/python3 ]] && \
    [[ "$(/usr/bin/python3 -c 'import sys; print(sys.version)')" != "$(python3 -c 'import sys; print(sys.version)')" ]]; then
    PYS+=(/usr/bin/python3)
fi

if [[ ! -f "$INBOX" ]]; then
    echo "test-series-inbox.sh: 検査対象が見つからない: $INBOX" >&2
fi

run_no=0
for PY in "${PYS[@]}"; do
    run_no=$((run_no + 1))
    WORK="$BASE/run-$run_no"
    mkdir -p "$WORK"
    LABEL="[$("$PY" -c 'import sys; print("py%d.%d" % sys.version_info[:2])')] "
    echo "== ${PY}（$("$PY" --version 2>&1)）=="
    run_tests
done

echo
echo "${pass_count} passed / ${fail_count} failed（python: ${PYS[*]}）"
[[ "$fail_count" -eq 0 ]] || exit 1
