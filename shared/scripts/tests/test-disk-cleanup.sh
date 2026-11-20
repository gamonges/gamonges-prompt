#!/usr/bin/env bash
# disk-cleanup.sh（launchd から毎晩起動するディスク掃除）の挙動テスト。
#
# 守りたいのは「1:00〜7:59 の間に 1 日 1 回だけ動く」「再生成できるものだけを消す」
# 「判断が要るもの（空き不足・マージ済み worktree）は通知だけにする」。時間帯の判定が壊れると
# 日中に重い prune が走り、対象が広がると Docker のボリュームのような取り返せないものを消す。
# どちらも launchd の裏で起きるので、普段の操作では気づけない。
#
# 実物は一切消さない。PATH の先頭に偽のコマンドを置き、呼ばれた引数を記録して確かめる。
#
# 起動: bash shared/scripts/tests/test-disk-cleanup.sh

# set -e は使わない。1 件目の失敗で残りが走らなくなると、Red で全件の失敗を確かめられない
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DC="$REPO_ROOT/shared/scripts/disk-cleanup.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass_count=0
fail_count=0

pass() { echo -e "${GREEN}PASS${NC} $1"; pass_count=$((pass_count + 1)); }
fail() { echo -e "${RED}FAIL${NC} $1"; [ -n "${2:-}" ] && echo "     $2"; fail_count=$((fail_count + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- 偽コマンド -------------------------------------------------------------
BIN="$WORK/bin"
mkdir -p "$BIN"
make_stub() {
    # 呼ばれた引数を CALLS に 1 行で残す
    cat > "$BIN/$1" <<EOF
#!/usr/bin/env bash
echo "$1 \$*" >> "\$FAKE_CALLS"
$2
EOF
    chmod +x "$BIN/$1"
}
make_stub uv ''
make_stub pnpm ''
make_stub brew ''
make_stub osascript ''
make_stub docker '[ "$1" = info ] && [ "${FAKE_DOCKER_DOWN:-0}" = 1 ] && exit 1; exit 0'
# df -k の形で空き（KB）を返す
make_stub df 'printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk3s5 482000000 1 %s 50%% /System/Volumes/Data\n" "$FAKE_FREE_KB"'
# gh pr list は FAKE_MERGED_BRANCHES の各ブランチを MERGED として返す
make_stub gh 'printf "["; sep=""; for b in ${FAKE_MERGED_BRANCHES:-}; do printf "%s{\"headRefName\":\"%s\",\"state\":\"MERGED\"}" "$sep" "$b"; sep=","; done; printf "]\n"'

# 1 件ごとに状態を作り直して実行する。引数は env の上書き（KEY=VALUE…）
run_case() {
    rm -rf "$WORK/state" "$WORK/caches" "$WORK/wt" "$WORK/calls" "$WORK/log"
    mkdir -p "$WORK/state" "$WORK/caches/com.example.app/org.sparkle-project.Sparkle" \
        "$WORK/caches/orca-updater" "$WORK/caches/keep-me" "$WORK/wt"
    : > "$WORK/calls"
    env PATH="$BIN:/usr/bin:/bin" \
        FAKE_CALLS="$WORK/calls" \
        FAKE_FREE_KB=$((200 * 1024 * 1024)) \
        DISK_CLEANUP_STATE_DIR="$WORK/state" \
        DISK_CLEANUP_LOG="$WORK/log" \
        DISK_CLEANUP_CACHES_DIR="$WORK/caches" \
        DISK_CLEANUP_WORKTREE_ROOT="$WORK/wt" \
        DISK_CLEANUP_HOUR=3 \
        "$@" bash "$DC" > "$WORK/out" 2>&1
    echo $? > "$WORK/rc"
}
called() { rg -q -- "$1" "$WORK/calls"; }

# --- 時間帯と 1 日 1 回 ------------------------------------------------------

run_case DISK_CLEANUP_HOUR=9
if [ ! -s "$WORK/calls" ] && [ ! -e "$WORK/state/last-run" ]; then
    pass "時間帯外（9 時）は何も呼ばずスタンプも書かない"
else
    fail "時間帯外（9 時）は何も呼ばずスタンプも書かない" "calls: $(cat "$WORK/calls")"
fi

run_case DISK_CLEANUP_HOUR=0
[ ! -s "$WORK/calls" ] && pass "0 時は時間帯外" || fail "0 時は時間帯外" "calls: $(cat "$WORK/calls")"

run_case DISK_CLEANUP_HOUR=8
[ ! -s "$WORK/calls" ] && pass "8 時は時間帯外（1:00〜7:59 だけ）" || fail "8 時は時間帯外（1:00〜7:59 だけ）"

run_case DISK_CLEANUP_HOUR=1
called "^uv cache prune" && pass "1 時は時間帯内" || fail "1 時は時間帯内" "out: $(cat "$WORK/out")"

run_case
if [ -e "$WORK/state/last-run" ] && [ "$(cat "$WORK/state/last-run")" = "$(date +%F)" ]; then
    pass "実行したら今日の日付をスタンプに書く"
else
    fail "実行したら今日の日付をスタンプに書く"
fi

# 同じ日の 2 回目（launchd は 1〜7 時の毎時に起動する）
rm -f "$WORK/calls.2"
mkdir -p "$WORK/state2"; date +%F > "$WORK/state2/last-run"
run_case DISK_CLEANUP_STATE_DIR="$WORK/state2"
[ ! -s "$WORK/calls" ] && pass "今日すでに実行済みなら何もしない" || fail "今日すでに実行済みなら何もしない" "calls: $(cat "$WORK/calls")"
echo "2000-01-01" > "$WORK/state2/last-run"
run_case DISK_CLEANUP_STATE_DIR="$WORK/state2"
called "^uv cache prune" && pass "スタンプが前日以前なら実行する" || fail "スタンプが前日以前なら実行する"

run_case DISK_CLEANUP_HOUR=14 DISK_CLEANUP_FORCE=1
called "^uv cache prune" && pass "DISK_CLEANUP_FORCE=1 は時間帯とスタンプを無視する" || fail "DISK_CLEANUP_FORCE=1 は時間帯とスタンプを無視する"

# --- 自動で消すもの ----------------------------------------------------------

run_case
called "^uv cache prune$" && pass "uv cache prune（clean ではない）" || fail "uv cache prune（clean ではない）" "calls: $(cat "$WORK/calls")"
called "^uv cache clean" && fail "uv cache clean は呼ばない" || pass "uv cache clean は呼ばない"
called "^pnpm store prune" && pass "pnpm store prune" || fail "pnpm store prune"
called "^brew cleanup" && pass "brew cleanup" || fail "brew cleanup"
called "^docker image prune -a -f --filter until=168h$" && pass "Docker は 7 日以上前の未使用イメージだけ" || fail "Docker は 7 日以上前の未使用イメージだけ" "calls: $(rg '^docker' "$WORK/calls")"
called "^docker builder prune -f --filter until=168h$" && pass "Docker のビルドキャッシュも 7 日" || fail "Docker のビルドキャッシュも 7 日"
if rg -q "^docker (volume|system|container)" "$WORK/calls"; then
    fail "Docker のボリューム・system・コンテナには触らない" "calls: $(rg '^docker' "$WORK/calls")"
else
    pass "Docker のボリューム・system・コンテナには触らない"
fi
if [ ! -e "$WORK/caches/com.example.app/org.sparkle-project.Sparkle" ] && [ ! -e "$WORK/caches/orca-updater" ] && [ -d "$WORK/caches/keep-me" ]; then
    pass "アプリ更新の残骸（Sparkle・*-updater）だけを消し、ほかのキャッシュは残す"
else
    fail "アプリ更新の残骸（Sparkle・*-updater）だけを消し、ほかのキャッシュは残す" "$(ls -R "$WORK/caches")"
fi

run_case FAKE_DOCKER_DOWN=1
if ! called "^docker image" && called "^uv cache prune"; then
    pass "Docker が止まっていれば Docker だけ飛ばす"
else
    fail "Docker が止まっていれば Docker だけ飛ばす" "calls: $(cat "$WORK/calls")"
fi

# 途中のコマンドが無くても残りは続ける
rm -f "$BIN/pnpm"
run_case
called "^brew cleanup" && pass "コマンドが無いものは飛ばして続ける" || fail "コマンドが無いものは飛ばして続ける" "out: $(cat "$WORK/out")"
make_stub pnpm ''

# --- 通知 --------------------------------------------------------------------

run_case FAKE_FREE_KB=$((49 * 1024 * 1024))
if called "^osascript" && rg -q "49" "$WORK/calls"; then
    pass "空きが 50GB 未満なら空き容量を通知する"
else
    fail "空きが 50GB 未満なら空き容量を通知する" "calls: $(rg '^osascript' "$WORK/calls")"
fi

run_case FAKE_FREE_KB=$((50 * 1024 * 1024))
called "^osascript" && fail "空き 50GB 以上・マージ済み 0 本なら通知しない" "calls: $(rg '^osascript' "$WORK/calls")" || pass "空き 50GB 以上・マージ済み 0 本なら通知しない"

# マージ済み worktree: <root>/<repo>/<worktree> に git の作業ツリーを作る
make_worktrees() {
    for spec in "$@"; do
        local d="$WORK/wt/$spec"; local b="${spec##*/}"
        mkdir -p "$d"
        git -C "$d" init -q -b "$b" 2>/dev/null
    done
}
run_case_with_wt() {
    # run_case は wt を作り直すので、作った後に実行するための版
    : > "$WORK/calls"; rm -rf "$WORK/state"; mkdir -p "$WORK/state"
    env PATH="$BIN:/usr/bin:/bin" FAKE_CALLS="$WORK/calls" FAKE_FREE_KB=$((200 * 1024 * 1024)) \
        DISK_CLEANUP_STATE_DIR="$WORK/state" DISK_CLEANUP_LOG="$WORK/log" \
        DISK_CLEANUP_CACHES_DIR="$WORK/caches" DISK_CLEANUP_WORKTREE_ROOT="$WORK/wt" \
        DISK_CLEANUP_HOUR=3 "$@" bash "$DC" > "$WORK/out" 2>&1
}
rm -rf "$WORK/wt"; mkdir -p "$WORK/wt"
make_worktrees repo-a/feat-x repo-a/feat-y repo-b/feat-z repo-b/main
run_case_with_wt FAKE_MERGED_BRANCHES="feat-x feat-z main"
notice="$(rg '^osascript' "$WORK/calls")"
if [ -n "$notice" ] && printf '%s' "$notice" | rg -q "2 本"; then
    pass "マージ済み worktree の本数を通知する（main は数えない）"
else
    fail "マージ済み worktree の本数を通知する（main は数えない）" "calls: $notice / out: $(cat "$WORK/out")"
fi
if [ -d "$WORK/wt/repo-a/feat-x" ]; then
    pass "マージ済み worktree は消さない（通知だけ）"
else
    fail "マージ済み worktree は消さない（通知だけ）"
fi

# --- ログ --------------------------------------------------------------------

run_case
if rg -q "空き" "$WORK/log" 2>/dev/null; then
    pass "前後の空き容量をログに残す"
else
    fail "前後の空き容量をログに残す" "log: $(cat "$WORK/log" 2>/dev/null)"
fi

echo
echo "pass: $pass_count / fail: $fail_count"
[ "$fail_count" -eq 0 ]
