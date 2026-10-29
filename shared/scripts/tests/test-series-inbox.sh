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

    # --- 登録が無い: 登録簿のディレクトリが無くても、空でも、render は成功する（初回の render を失敗させない） ---
    out="$(ib render 2>&1)"; rc=$?
    assert_rc "IB-0 登録簿のディレクトリが無い render は exit 0" 0 "$rc" "$out"
    assert_has "IB-0 登録が無いと出す" "$(cat "$DIR/inbox.html" 2>/dev/null)" "登録されたシリーズは無い"
    mkdir -p "$DIR/registry"
    out="$(ib render 2>&1)"; rc=$?
    assert_rc "IB-0 空の登録簿の render は exit 0" 0 "$rc" "$out"
    assert_has "IB-0 空の登録簿でも登録が無いと出す" "$(cat "$DIR/inbox.html" 2>/dev/null)" "登録されたシリーズは無い"

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
    bad="$(sed -E 's#<a href="[^"]*">[^<]*</a>##g' "$DIR/inbox.html" | grep -cE 'https?://' || true)"
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

    # --- HTML のエスケープ: 題名と本文の <script>・& をそのまま出さない ---
    local se="$WORK/e/tmp/series-run.md"
    write_state "$se" "- Q-1（e1）: <script>x</script> & https://e.com/?a=1&b=2 と https://e.com/y" \
        "| $wa | e1 | review: 作業中 | worker | recheck |" ""
    ib register --state "$se" --terminal term_e --title "<b>T</b>" >/dev/null 2>&1
    ib render >/dev/null 2>&1
    view="$(cat "$DIR/inbox.html")"
    assert_not_has "IB-7 本文の <script> をそのまま出さない" "$view" "<script>x"
    assert_has "IB-7 本文の <script> をエスケープする" "$view" "&lt;script&gt;x&lt;/script&gt; &amp;"
    assert_not_has "IB-7 題名の <b> をそのまま出さない" "$view" "<b>T</b>"
    assert_has "IB-7 URL の & は href の中でもエスケープする" "$view" 'href="https://e.com/?a=1&amp;b=2"'
    bad="$(sed -E 's#<a href="[^"]*">[^<]*</a>##g' "$DIR/inbox.html" | grep -cE 'https?://' || true)"
    assert_eq "IB-7 同じ行の 2 つ目の URL もリンクの中にだけある" 0 "$bad"
    ib unregister --state "$se" >/dev/null 2>&1

    # --- 全作業単位が 完了 でも、残る依頼（④）があれば「終わった」にせず描画する ---
    local sr="$WORK/r/tmp/series-run.md"
    write_state "$sr" "- R-1（be1）: worktree a で指摘 3 を直す" "| $wa | be1 | 完了 | なし | — |" ""
    ib register --state "$sr" --terminal term_r --title "残る依頼の題名" >/dev/null 2>&1
    ib render >/dev/null 2>&1
    view="$(cat "$DIR/inbox.html")"
    assert_has "IB-8 完了の後に残る④を描画する" "$view" "R-1（be1）: worktree a で指摘 3 を直す"
    assert_eq "IB-8 残る④のあるシリーズは「終わった」にしない（IB-3 の 2 件のまま）" 2 \
        "$(grep -c '終わった（登録が残っている）' "$DIR/inbox.html" || true)"
    ib unregister --state "$sr" >/dev/null 2>&1

    # --- unregister: そのファイルだけ消す。無いものは exit 0 ---
    ib unregister --state "$sd" >/dev/null 2>&1; rc=$?
    assert_rc "IB-4 unregister は exit 0" 0 "$rc" ""
    assert_eq "IB-4 そのシリーズのファイルだけ消える" 3 "$(ls "$DIR/registry" | wc -l | tr -d ' ')"
    ib unregister --state "$sd" >/dev/null 2>&1; rc=$?
    assert_rc "IB-4 無いものの unregister も exit 0（冪等）" 0 "$rc" ""
    ib unregister --state "$sc" >/dev/null 2>&1

    # --- 形の違う登録: 1 件の壊れで全体の更新を止めない。traceback にしない ---
    local bad_entry
    for bad_entry in '{}' '[1]' "{\"state\":\"$sa\",\"title\":1,\"terminal\":\"t\"}" "{\"state\":\"$sa\",\"title\":\"t\",\"terminal\":null}"; do
        printf '%s\n' "$bad_entry" >"$DIR/registry/zz-bad.json"
        out="$(ib render 2>&1)"; rc=$?
        assert_rc "IB-9 形の違う登録 $bad_entry の render は exit 1" 1 "$rc" "$out"
        assert_not_has "IB-9 形の違う登録 $bad_entry で traceback を出さない" "$out" "Traceback"
        assert_has "IB-9 形の違う登録 $bad_entry があっても、ほかのシリーズは描画する" "$(cat "$DIR/inbox.html")" "注文の取込"
        assert_has "IB-9 形の違う登録 $bad_entry は読めないと出す" "$(cat "$DIR/inbox.html")" "読めない"
    done
    # 読めない登録が残っていても、register・unregister は失敗しない（移行のために全件を読むが、読めないものは飛ばす）
    out="$(ib register --state "$sb" --terminal term_b --title "請求の出力" 2>&1)"; rc=$?
    assert_rc "IB-9 読めない登録が残っていても register は exit 0" 0 "$rc" "$out"
    out="$(ib unregister --state "$WORK/none/tmp/series-run.md" 2>&1)"; rc=$?
    assert_rc "IB-9 読めない登録が残っていても unregister は exit 0" 0 "$rc" "$out"
    assert_eq "IB-9 読めない登録は移行で消さない" 1 "$(ls "$DIR/registry" | grep -c zz-bad || true)"
    # 読めない登録の state と同じ状態ファイルで register・unregister しても、読めない登録は消さない（形を確かめずに消さない）
    ib register --state "$sa" --terminal term_new --title "注文の取込" >/dev/null 2>&1
    ib unregister --state "$sa" >/dev/null 2>&1
    assert_eq "IB-9 同じ状態ファイルを指す読めない登録も移行で消さない" 1 "$(ls "$DIR/registry" | grep -c zz-bad || true)"
    ib register --state "$sa" --terminal term_new --title "注文の取込" >/dev/null 2>&1
    rm -f "$DIR/registry/zz-bad.json"

    # --- 読めない状態ファイル: そのシリーズだけ「読めない」と出し、ほかは更新して exit 1 ---
    cp "$sb" "$WORK/sb.bak"
    cp "$sa" "$WORK/sa.bak"
    printf '\xff\xfe broken\n' >"$sb"
    write_state "$sa" "- Q-7（be1）: 更新の確認" "| $wa | be1 | checks: 確認中 | なし | review |" ""
    out="$(ib render 2>&1)"; rc=$?
    assert_rc "IB-5 壊れた状態ファイルの render は exit 1" 1 "$rc" "$out"
    assert_has "IB-5 壊れたシリーズは読めないと出す" "$(cat "$DIR/inbox.html")" "読めない"
    assert_has "IB-5 ほかのシリーズの更新は反映する" "$(cat "$DIR/inbox.html")" "Q-7（be1）: 更新の確認"
    assert_has "IB-5 読めないシリーズにも登録の題名を出す（どこで直すかが分かる）" "$(cat "$DIR/inbox.html")" "<h2>請求の出力</h2>"
    cp "$WORK/sb.bak" "$sb"
    cp "$WORK/sa.bak" "$sa"
    # 書きかけを見せない: 置き換えに失敗したら、前のビューが残る（ディレクトリを書き込み不可にして一時ファイルを作らせない）
    ib render >/dev/null 2>&1
    cp "$DIR/inbox.html" "$WORK/before.html"
    write_state "$sa" "- Q-8（be1）: 見せてはいけない更新" "| $wa | be1 | checks: 確認中 | なし | review |" ""
    chmod 555 "$DIR"
    out="$(ib render 2>&1)"; rc=$?
    chmod 755 "$DIR"
    assert_rc "IB-5 置き換えに失敗した render は exit 1（書き込み不可）" 1 "$rc" "$out"
    if cmp -s "$WORK/before.html" "$DIR/inbox.html"; then pass "IB-5 置き換えに失敗しても前のビューが残る"; else fail "IB-5 置き換えに失敗しても前のビューが残る"; fi
    cp "$WORK/sa.bak" "$sa"
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
    if [[ -e "$WORK/locked" ]]; then pass "IB-6 前提: 先にロックを取れた"; else fail "IB-6 前提: 先にロックを取れた"; fi
    ib render >/dev/null 2>&1 &
    local renderer=$!
    "$PY" -c 'import time; time.sleep(1)'
    write_state "$sa" "- Q-9（be1）: 新しい問い" "| $wa | be1 | checks: 確認中 | なし | review |" ""
    wait "$locker"
    wait "$renderer"
    view="$(cat "$DIR/inbox.html")"
    assert_has "IB-6 ロックを待った render は新しい状態でビューを作る" "$view" "Q-9（be1）: 新しい問い"
    assert_not_has "IB-6 古い状態（Q-1）で巻き戻さない" "$view" "Q-1（be1）"

    # --- 登録のキーは realpath: symlink 違いの同じ状態ファイルを 1 件にまとめ、旧形式（abspath のキー）を移す ---
    DIR="$WORK/state-real"
    mkdir -p "$WORK/real/x/tmp"
    ln -s "$WORK/real" "$WORK/link"
    local sreal="$WORK/real/x/tmp/series-run.md" slink="$WORK/link/x/tmp/series-run.md"
    write_state "$sreal" "" "| $wa | be1 | review: 作業中 | worker | recheck |" ""
    ib register --state "$slink" --terminal t1 --title "表記の違い" >/dev/null 2>&1
    ib register --state "$sreal" --terminal t2 --title "表記の違い" >/dev/null 2>&1
    assert_eq "IB-10 symlink 違いの同じ状態ファイルは 1 件" 1 "$(ls "$DIR/registry" | wc -l | tr -d ' ')"
    rm -f "$DIR/registry/"*.json
    # 旧版の登録（abspath の sha1 をファイル名にし、state に abspath を書いた JSON）を事前に置く
    local oldkey
    oldkey="$("$PY" -c 'import hashlib,sys; print(hashlib.sha1(sys.argv[1].encode()).hexdigest()[:16])' "$slink")"
    printf '{"state": "%s", "terminal": "t0", "title": "旧形式"}\n' "$slink" >"$DIR/registry/$oldkey.json"
    ib register --state "$sreal" --terminal t2 --title "表記の違い" >/dev/null 2>&1
    assert_eq "IB-10 旧形式の登録は別の表記の register で移る（1 件）" 1 "$(ls "$DIR/registry" | wc -l | tr -d ' ')"
    printf '{"state": "%s", "terminal": "t0", "title": "旧形式"}\n' "$slink" >"$DIR/registry/$oldkey.json"
    ib unregister --state "$sreal" >/dev/null 2>&1
    assert_eq "IB-10 旧形式の登録も別の表記の unregister で消える（0 件）" 0 "$(ls "$DIR/registry" | wc -l | tr -d ' ')"

    # --- 並びのキーは「- 」で始まる行の数（複数行の 1 問を 3 問と数えない） ---
    DIR="$WORK/state-order"
    local s1="$WORK/o1/tmp/series-run.md" s2="$WORK/o2/tmp/series-run.md"
    write_state "$s1" "- Q-1（a）: 長い問い
  続きの行
  続きの行" "| $wa | a | design: 判断待ち | ユーザー | design |" ""
    write_state "$s2" "- Q-1（b）: 問い 1
- Q-2（b）: 問い 2" "| $wb | b | design: 判断待ち | ユーザー | design |" ""
    ib register --state "$s1" --terminal t1 --title "AAA 1 問" >/dev/null 2>&1
    ib register --state "$s2" --terminal t2 --title "BBB 2 問" >/dev/null 2>&1
    ib render >/dev/null 2>&1
    first="$(grep -oE 'AAA 1 問|BBB 2 問' "$DIR/inbox.html" | head -1)"
    assert_eq "IB-11 問いの多いシリーズが上（行数でなく問いの数）" "BBB 2 問" "$first"
}

# python3 と /usr/bin/python3 が別物なら両方で全件を回す（3.9 で動くことの検証）
PYS=(python3)
if [[ -x /usr/bin/python3 ]] && \
    [[ "$(/usr/bin/python3 -c 'import sys; print(sys.version)')" != "$(python3 -c 'import sys; print(sys.version)')" ]]; then
    PYS+=(/usr/bin/python3)
fi

if [[ ! -f "$INBOX" ]]; then
    echo "test-series-inbox.sh: 検査対象が見つからない: $INBOX" >&2
    exit 1
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
