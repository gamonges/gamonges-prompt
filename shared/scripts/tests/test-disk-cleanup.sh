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

# アサートは /usr/bin/grep で行う。rg のような外部ツールに頼ると、無い環境で `called … && fail || pass`
# の否定のアサートが空振りで PASS する（呼び出しの失敗が「見つからない」に化ける）
GREP=/usr/bin/grep
if [ ! -x "$GREP" ]; then
    echo "FAIL $GREP が無い（アサートが空振りするので止める）"
    exit 1
fi

# --- 偽コマンド -------------------------------------------------------------
BIN="$WORK/bin"
mkdir -p "$BIN"
# 呼ばれた引数を CALLS に 1 行で、cwd 付きの行を CALLS.pwd に残す。
# FAKE_HANG・FAKE_FAIL に名前が入っている stub だけが、ハング（孫を作って待つ）・失敗する。
# 孫の sleep の端数は、timeout の後に孫が残っていないかを pgrep で探す目印
make_stub() {
    cat > "$BIN/$1" <<EOF
#!/usr/bin/env bash
echo "$1 \$*" >> "\$FAKE_CALLS"
echo "$1 \$* @ \$PWD" >> "\$FAKE_CALLS.pwd"
case " \${FAKE_HANG:-} " in *" $1 "*) [ "\${FAKE_HANG_IGNORE_TERM:-0}" = 1 ] && trap '' TERM; sleep 30.1234 & wait; exit 0 ;; esac
case " \${FAKE_FAIL:-} " in *" $1 "*) exit 1 ;; esac
$2
EOF
    chmod +x "$BIN/$1"
}
make_stub uv ''
make_stub pnpm ''
make_stub brew ''
make_stub osascript ''
# docker はイメージの一覧を FAKE_DOCKER_IMAGES（`id|作成時刻|RepoDigests の数|タグ（空白区切り。無ければ空）` を
# `;` でつなぐ）、コンテナが使うイメージを FAKE_DOCKER_USED_IMAGES（空白区切りの ID）で受け取る
make_stub docker '
case "$1 ${2:-}" in
    "info "*) [ "${FAKE_DOCKER_DOWN:-0}" = 1 ] && exit 1; exit 0 ;;
    "ps -aq") [ "${FAKE_DOCKER_PS_FAIL:-0}" = 1 ] && exit 1; [ -n "${FAKE_DOCKER_USED_IMAGES:-}" ] && echo c1; exit 0 ;;
    "inspect --format") printf "%s\n" ${FAKE_DOCKER_USED_IMAGES:-}; exit 0 ;;
    "image ls") IFS=";"; for l in ${FAKE_DOCKER_IMAGES:-}; do echo "${l%%|*}"; done; exit 0 ;;
    "image inspect") id="${!#}"; IFS=";"; for l in ${FAKE_DOCKER_IMAGES:-}; do [ "${l%%|*}" = "$id" ] && { echo "$l"; exit 0; }; done; exit 1 ;;
    "image rm") [ "${FAKE_DOCKER_RM_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
esac
exit 0'
# df -k の形で空き（KB）を返す
make_stub df 'printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk3s5 482000000 1 %s 50%% /System/Volumes/Data\n" "$FAKE_FREE_KB"'
# gh pr list --head <b> は、b が FAKE_MERGED_BRANCHES にあれば 1（件数）、無ければ 0 を返す。
# --author が付いていたら 0 を返す（/worktree-cleanup と同じく author で絞らないことを確かめるため）
make_stub gh '
case " $* " in *" --author "*) echo 0; exit 0 ;; esac
b=""; prev=""
for a in "$@"; do [ "$prev" = --head ] && b="$a"; prev="$a"; done
for m in ${FAKE_MERGED_BRANCHES:-}; do [ "$m" = "$b" ] && { echo 1; exit 0; }; done
echo 0'

# 状態・キャッシュ・worktree・記録を作り直す
reset_state() {
    rm -rf "$WORK/state" "$WORK/caches" "$WORK/wt" "$WORK/calls" "$WORK/calls.pwd" "$WORK/log" "$WORK/out" "$WORK/rc"
    mkdir -p "$WORK/state" "$WORK/caches/com.example.app/org.sparkle-project.Sparkle" \
        "$WORK/caches/orca-updater" "$WORK/caches/keep-me" "$WORK/wt"
    : > "$WORK/calls"
}

# 実行する。引数は env の上書き（KEY=VALUE…）。スクリプトは常に exit 0 で終わる約束なので、
# 0 以外なら FAIL を 1 件足す（PASS は数えない。ケースごとの件数を変えないため）
run_dc() {
    # ロケールは UTF-8 に固定する。UTF-8 の bash は「$name（」の全角文字のバイトを変数名の続きとして読み、
    # set -u で落ちる（C ロケールでは起きない）。呼び出し元のロケールで結果が変わらないよう、厳しい側でそろえる
    env PATH="$BIN:/usr/bin:/bin" \
        LC_ALL=en_US.UTF-8 \
        FAKE_CALLS="$WORK/calls" \
        FAKE_FREE_KB=$((200 * 1024 * 1024)) \
        DISK_CLEANUP_STATE_DIR="$WORK/state" \
        DISK_CLEANUP_LOG="$WORK/log" \
        DISK_CLEANUP_CACHES_DIR="$WORK/caches" \
        DISK_CLEANUP_WORKTREE_ROOT="$WORK/wt" \
        DISK_CLEANUP_HOUR=3 \
        "$@" bash "$DC" > "$WORK/out" 2>&1
    echo $? > "$WORK/rc"
    assert_rc0 "$*"
}
assert_rc0() {
    local rc; rc="$(cat "$WORK/rc")"
    [ "$rc" = 0 ] || fail "exit 0 で終わる（${1:-既定}）" "rc=$rc out: $(cat "$WORK/out")"
}
run_case() { reset_state; run_dc "$@"; }
called() { "$GREP" -qE -- "$1" "$WORK/calls"; }

# 土台の確かめ: 何も呼ばれていない記録に対して called が偽を返す（常に真なら否定のアサートが全部落ち、
# 常に偽なら肯定のアサートが全部落ちるので、両方を 1 件ずつ見る）
reset_state
if called '^uv '; then fail "called は記録に無い呼び出しで偽を返す"; else pass "called は記録に無い呼び出しで偽を返す"; fi
echo "uv cache prune" > "$WORK/calls"
if called '^uv cache prune$'; then pass "called は記録にある呼び出しで真を返す"; else fail "called は記録にある呼び出しで真を返す"; fi

# 期待どおりなら PASS、違えば FAIL（2 つ目の引数は FAIL のときに出す材料）
check() {  # $1=名前, $2=判定のコマンド（文字列で eval する）, $3=FAIL のときの材料
    if eval "$2"; then pass "$1"; else fail "$1" "${3:-}"; fi
}
notice() { "$GREP" -E '^osascript' "$WORK/calls"; }
logged() { "$GREP" -qE -- "$1" "$WORK/log" 2>/dev/null; }
days_ago() { date -v-"$1"d +%F; }

# 更新の残骸の置き場を、親も子も 2 日前の mtime にする（作ったばかりだと「24 時間以内に更新」で残るため）
age_caches() {
    local old; old="$(date -v-2d +%Y%m%d%H%M)"
    find "$WORK/caches" -exec touch -t "$old" {} +
}

# --- 時間帯と 1 日 1 回 ------------------------------------------------------

run_case DISK_CLEANUP_HOUR=9
check "時間帯外（9 時）は何も呼ばずスタンプも書かない" '[ ! -s "$WORK/calls" ] && [ ! -e "$WORK/state/last-run" ]' "calls: $(cat "$WORK/calls")"

run_case DISK_CLEANUP_HOUR=0
check "0 時は時間帯外" '[ ! -s "$WORK/calls" ]' "calls: $(cat "$WORK/calls")"

run_case DISK_CLEANUP_HOUR=8
check "8 時は時間帯外（1:00〜7:59 だけ）" '[ ! -s "$WORK/calls" ]'

run_case DISK_CLEANUP_HOUR=1
check "1 時は時間帯内" 'called "^uv cache prune"' "out: $(cat "$WORK/out")"

run_case DISK_CLEANUP_HOUR=7
check "7 時は時間帯内（上端）" 'called "^uv cache prune"' "out: $(cat "$WORK/out")"

# date +%H は 08・09 を返す。10# が無いと 8 進数として読んで落ちる
run_case DISK_CLEANUP_HOUR=08
check "08 時（ゼロ埋め）は時間帯外で、エラーにならない" '[ ! -s "$WORK/calls" ] && ! "$GREP" -q "value too great" "$WORK/out"' "out: $(cat "$WORK/out")"

run_case
check "実行したら今日の日付をスタンプに書く" '[ "$(cat "$WORK/state/last-run" 2>/dev/null)" = "$(date +%F)" ]'

# 同じ日の 2 回目（launchd は 1〜7 時の毎時に起動する）
reset_state; date +%F > "$WORK/state/last-run"; run_dc
check "今日すでに実行済みなら何もしない" '[ ! -s "$WORK/calls" ]' "calls: $(cat "$WORK/calls")"
reset_state; echo "2000-01-01" > "$WORK/state/last-run"; run_dc
check "スタンプが前日以前なら実行する" 'called "^uv cache prune"'

run_case DISK_CLEANUP_HOUR=14 DISK_CLEANUP_FORCE=1
check "DISK_CLEANUP_FORCE=1 は時間帯とスタンプを無視する" 'called "^uv cache prune"'

# --- 止めるファイル ----------------------------------------------------------

reset_state; : > "$WORK/state/disabled"; run_dc DISK_CLEANUP_FORCE=1
check "disabled があれば FORCE でも何も呼ばない" '[ ! -s "$WORK/calls" ]' "calls: $(cat "$WORK/calls")"
check "disabled があれば last-run を書かない" '[ ! -e "$WORK/state/last-run" ]'
run_dc DISK_CLEANUP_FORCE=1
check "disabled のログは同じ日に 1 行だけ" '[ "$("$GREP" -c "skip disabled" "$WORK/log")" = 1 ]' "log: $(cat "$WORK/log" 2>/dev/null)"
# 時間帯外の未実行の通知も止める
reset_state; : > "$WORK/state/disabled"; days_ago 5 > "$WORK/state/last-run"; run_dc DISK_CLEANUP_HOUR=14
check "disabled があれば未実行の通知も出さない" '! called "^osascript"' "calls: $(cat "$WORK/calls")"

# --- 自動で消すもの ----------------------------------------------------------

run_case
check "uv cache prune（clean ではない）" 'called "^uv cache prune$"' "calls: $(cat "$WORK/calls")"
check "uv cache clean は呼ばない" '! called "^uv cache clean"'
# launchd が与える cwd に依存しないよう、HOME を明示して流す（サブシェルで cd すると失敗の集計が親に戻らない）
check "pnpm store prune を HOME で流す" 'called "^pnpm --dir $HOME store prune$"' "calls: $("$GREP" -E '^pnpm' "$WORK/calls")"
check "brew cleanup" 'called "^brew cleanup"'
check "Docker のビルドキャッシュは 7 日" 'called "^docker builder prune -f --filter until=168h$"'
check "Docker のボリューム・system・コンテナには触らない" '! "$GREP" -qE "^docker (volume|system|container)" "$WORK/calls"' "calls: $("$GREP" -E '^docker' "$WORK/calls")"
check "一括の docker image prune は呼ばない（-a の有無に関わらず）" '! called "^docker image prune"' "calls: $("$GREP" -E '^docker' "$WORK/calls")"

# Docker のイメージ: digest あり・未使用（停止中のコンテナも含む）・作成から 7 日以上の 3 つを満たすものだけを消す。
# 作成時刻は相対の日付で作る（固定の日付だと、時間がたつと「2 日前」が 7 日を超える）
d8="$(date -u -v-8d +%Y-%m-%dT%H:%M:%SZ)"
d2="$(date -u -v-2d +%Y-%m-%dT%H:%M:%SZ)"
IMGS="sha256:a|$d8|1|nginx:old;sha256:b|$d8|0|myapp:dev;sha256:c|$d8|1|redis:7;sha256:d|$d2|1|pg:16;sha256:e|$d8|1|;sha256:f|$d8|0|"
run_case FAKE_DOCKER_IMAGES="$IMGS" FAKE_DOCKER_USED_IMAGES="sha256:c"
DOCKER_CALLS="$("$GREP" -E '^docker image rm' "$WORK/calls")"
check "(a) digest あり・タグ付き・未使用・8 日前 → タグで消す" 'called "^docker image rm nginx:old$"' "rm: $DOCKER_CALLS"
check "(b) digest 無し（ローカルビルド）・タグ付き → 消さない" '! called "^docker image rm (myapp:dev|sha256:b)$"' "rm: $DOCKER_CALLS"
check "(c) 停止中のコンテナが使う → 消さない" '! called "^docker image rm (redis:7|sha256:c)$"' "rm: $DOCKER_CALLS"
check "(d) 作成から 2 日 → 消さない" '! called "^docker image rm (pg:16|sha256:d)$"' "rm: $DOCKER_CALLS"
check "(e) digest あり・タグ無し・未使用・8 日前 → ID で消す" 'called "^docker image rm sha256:e$"' "rm: $DOCKER_CALLS"
check "(f) digest 無し・タグ無し（commit したもの） → 消さない" '! called "^docker image rm sha256:f$"' "rm: $DOCKER_CALLS"
# 使用中の集合を作れなければ（docker ps の失敗）、何も消さずに段の失敗にする（集合が空のまま進むと、使用中のイメージまで消す）
run_case FAKE_DOCKER_IMAGES="$IMGS" FAKE_DOCKER_USED_IMAGES="sha256:c" FAKE_DOCKER_PS_FAIL=1
check "使用中のコンテナを確かめられなければ、イメージを消さない" '! called "^docker image rm"' "calls: $("$GREP" -E '^docker' "$WORK/calls")"
check "使用中のコンテナを確かめられないのは、段の失敗として通知に出す" 'notice | "$GREP" -q "失敗: docker-images"' "notice: $(notice)"
run_case FAKE_DOCKER_IMAGES="$IMGS" FAKE_DOCKER_USED_IMAGES="sha256:c" FAKE_DOCKER_RM_FAIL=1
check "(i) rm が失敗しても残りのイメージを試す" 'called "^docker image rm nginx:old$" && called "^docker image rm sha256:e$"' "calls: $("$GREP" -E '^docker' "$WORK/calls")"
check "(i) rm の失敗は通知に「失敗: docker-images」で出る" 'notice | "$GREP" -q "失敗: docker-images"' "notice: $(notice)"

# 更新の残骸: 配下も含めて 24 時間以内に触られたものは残す（インストールの途中で消すと更新が壊れうる）
reset_state; age_caches; run_dc
check "アプリ更新の残骸（Sparkle・*-updater）は、古ければ消す" '[ ! -e "$WORK/caches/com.example.app/org.sparkle-project.Sparkle" ] && [ ! -e "$WORK/caches/orca-updater" ]' "$(ls -R "$WORK/caches")"
check "ほかのキャッシュは残す" '[ -d "$WORK/caches/keep-me" ]'
reset_state
mkdir -p "$WORK/caches/com.example.app/org.sparkle-project.Sparkle/deep/dir" "$WORK/caches/orca-updater/deep/dir"
: > "$WORK/caches/com.example.app/org.sparkle-project.Sparkle/deep/dir/new"
: > "$WORK/caches/orca-updater/deep/dir/new"
age_caches
touch "$WORK/caches/com.example.app/org.sparkle-project.Sparkle/deep/dir/new" "$WORK/caches/orca-updater/deep/dir/new"
run_dc
check "親が古くても、深い階層に新しいファイルがあれば残す（Sparkle）" '[ -d "$WORK/caches/com.example.app/org.sparkle-project.Sparkle" ]'
check "親が古くても、深い階層に新しいファイルがあれば残す（*-updater）" '[ -d "$WORK/caches/orca-updater" ]'
reset_state; run_dc
check "作ったばかり（mtime が今）なら残す" '[ -d "$WORK/caches/com.example.app/org.sparkle-project.Sparkle" ] && [ -d "$WORK/caches/orca-updater" ]'
# 更新時刻を確かめられない（読めない配下がある）なら、消さない側に倒す
reset_state; mkdir -p "$WORK/caches/orca-updater/locked"; age_caches; chmod 000 "$WORK/caches/orca-updater/locked"
run_dc
chmod 755 "$WORK/caches/orca-updater/locked"
check "配下を読めず更新時刻を確かめられなければ残す" '[ -d "$WORK/caches/orca-updater" ] && logged "skip .*orca-updater（更新時刻を確かめられない）"' "log: $(cat "$WORK/log" 2>/dev/null)"
# 消せなかったら（親に書き込めない）、ログに残し、通知に「失敗: updater」を出す。このループは step を通らないので、
# 段の失敗の集計とは別に確かめる
reset_state; age_caches; chmod 555 "$WORK/caches/com.example.app"
run_dc
chmod 755 "$WORK/caches/com.example.app"
check "更新の残骸を消せなければログに残す" 'logged "failed rm .*org.sparkle-project.Sparkle"' "log: $(cat "$WORK/log" 2>/dev/null)"
check "更新の残骸を消せなければ、通知に「失敗: updater」を出す" 'notice | "$GREP" -q "失敗: updater"' "notice: $(notice)"

run_case FAKE_DOCKER_DOWN=1
check "Docker が止まっていれば Docker だけ飛ばす" '! called "^docker image" && ! called "^docker builder" && called "^uv cache prune"' "calls: $(cat "$WORK/calls")"
check "Docker が止まっているのは失敗に数えない" '! notice | "$GREP" -q "失敗"' "notice: $(notice)"

# 途中のコマンドが無くても残りは続ける
rm -f "$BIN/pnpm"
run_case
check "コマンドが無いものは飛ばして続ける" 'called "^brew cleanup"' "out: $(cat "$WORK/out")"
make_stub pnpm ''

# --- 失敗とタイムアウト --------------------------------------------------------

run_case FAKE_FAIL=uv
check "段が失敗しても残りの段を続ける" 'called "^brew cleanup" && called "^docker builder"' "calls: $(cat "$WORK/calls")"
check "失敗した段の名前を通知に出す" 'notice | "$GREP" -q "失敗: uv"' "notice: $(notice)"
run_case FAKE_FAIL=pnpm
check "pnpm の失敗も通知に出る（サブシェルで集計が消えない）" 'notice | "$GREP" -q "失敗: pnpm"' "notice: $(notice)"

start=$(date +%s)
run_case FAKE_HANG=uv DISK_CLEANUP_STEP_TIMEOUT=2
elapsed=$(( $(date +%s) - start ))
sleep 1
check "ハングした段はタイムアウトで打ち切り、20 秒以内に終わる（stub は 30 秒眠る）" '[ "$elapsed" -lt 20 ]' "elapsed=${elapsed}s"
check "タイムアウトした段の後も続ける" 'called "^brew cleanup"' "calls: $(cat "$WORK/calls")"
check "タイムアウトをログに残す" 'logged "timeout uv"' "log: $(cat "$WORK/log" 2>/dev/null)"
check "タイムアウトも失敗として通知に出す" 'notice | "$GREP" -q "失敗: uv"' "notice: $(notice)"
check "タイムアウトで終わってもスタンプは残る（先に書く）" '[ "$(cat "$WORK/state/last-run" 2>/dev/null)" = "$(date +%F)" ]'
check "タイムアウトの後に、段の孫のプロセスが残らない" '! pgrep -f "sleep 30.1234" >/dev/null' "$(pgrep -fl 'sleep 30.1234')"
check "タイムアウトの後に、監視側の sleep が残らない" '! pgrep -f "^sleep 2$" >/dev/null' "$(pgrep -fl '^sleep 2$')"

# TERM を無視する段（孫も無視を引き継ぐ）は、TERM の 5 秒後の KILL で止める
start=$(date +%s)
run_case FAKE_HANG=uv FAKE_HANG_IGNORE_TERM=1 DISK_CLEANUP_STEP_TIMEOUT=1
elapsed=$(( $(date +%s) - start ))
sleep 1
check "TERM を無視する段も KILL で止め、20 秒以内に終わる" '[ "$elapsed" -lt 20 ] && logged "timeout uv"' "elapsed=${elapsed}s log: $(cat "$WORK/log" 2>/dev/null)"
check "TERM を無視する段の孫も残らない" '! pgrep -f "sleep 30.1234" >/dev/null' "$(pgrep -fl 'sleep 30.1234')"

# --- 通知 --------------------------------------------------------------------

run_case FAKE_FREE_KB=$((49 * 1024 * 1024))
check "空きが 50GB 未満なら空き容量を通知する" 'notice | "$GREP" -q "空き 49GB"' "notice: $(notice)"
check "通知の結果をログに残す" 'logged "notify sent \(exit 0\)"' "log: $(cat "$WORK/log" 2>/dev/null)"

run_case FAKE_FREE_KB=$((49 * 1024 * 1024)) FAKE_FAIL=osascript
check "通知に失敗したらログに残す" 'logged "notify failed \(exit 1\)"' "log: $(cat "$WORK/log" 2>/dev/null)"

run_case FAKE_FREE_KB=$((50 * 1024 * 1024))
check "空き 50GB 以上・マージ済み 0 本なら通知しない" '! called "^osascript"' "notice: $(notice)"

# マージ済み worktree: <root>/<repo>/<worktree> に git の作業ツリーを作る
make_worktrees() {
    for spec in "$@"; do
        local d="$WORK/wt/$spec"; local b="${spec##*/}"
        mkdir -p "$d"
        git -C "$d" init -q -b "$b" 2>/dev/null
    done
}
# HEAD を切り離した worktree（ブランチ名が空）
make_detached() {
    local d="$WORK/wt/$1"
    mkdir -p "$d"
    git -C "$d" init -q -b tmp 2>/dev/null
    git -C "$d" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init 2>/dev/null
    git -C "$d" checkout -q --detach 2>/dev/null
}

reset_state
make_worktrees repo-a/feat-x repo-a/feat-y repo-b/feat-z repo-b/main repo-b/develop
make_detached repo-b/detached
run_dc FAKE_MERGED_BRANCHES="feat-x feat-z main"
check "マージ済み worktree の本数と repo ごとの内訳を通知する" 'notice | "$GREP" -q "マージ済み worktree 2 本（repo-a 1・repo-b 1）"' "notice: $(notice) / out: $(cat "$WORK/out")"
check "gh は worktree の中で、ブランチ名で問い合わせる" '"$GREP" -qE "^gh .*--head feat-x .* @ $WORK/wt/repo-a/feat-x/?$" "$WORK/calls.pwd"' "$("$GREP" -E '^gh' "$WORK/calls.pwd")"
check "main・develop・detached は問い合わせない" '! "$GREP" -qE "^gh .*--head (main|develop|tmp)( |$)" "$WORK/calls" && [ "$("$GREP" -c "^gh " "$WORK/calls")" = 3 ]' "$("$GREP" -E '^gh' "$WORK/calls")"
check "マージ済み worktree は消さない（通知だけ）" '[ -d "$WORK/wt/repo-a/feat-x" ]'

# 空き不足とマージ済みが同時なら、1 つの通知に ` / ` でつなぐ
reset_state; make_worktrees repo-a/feat-x
run_dc FAKE_MERGED_BRANCHES="feat-x" FAKE_FREE_KB=$((49 * 1024 * 1024))
check "通知が 2 件なら ' / ' でつなぐ" 'notice | "$GREP" -q "空き 49GB（50GB 未満） / マージ済み worktree 1 本"' "notice: $(notice)"

# gh が失敗した repo は「0 本」と区別し、その repo の残りには問い合わせない
reset_state; make_worktrees repo-a/feat-x repo-a/feat-y
run_dc FAKE_FAIL=gh
check "gh が失敗した repo を数えてログに残す" 'logged "確認できなかった repo 1 件"' "log: $(cat "$WORK/log" 2>/dev/null)"
check "gh が失敗した repo を通知に出す" 'notice | "$GREP" -q "worktree を確認できなかった repo 1 件"' "notice: $(notice)"
check "gh が失敗したら「0 本」と書かない" '! logged "マージ済み worktree 0 本"' "log: $(cat "$WORK/log" 2>/dev/null)"
check "gh が失敗した repo の残りの worktree には問い合わせない" '[ "$("$GREP" -c "^gh " "$WORK/calls")" = 1 ]' "$("$GREP" -E '^gh' "$WORK/calls")"

# --- 時間帯外の未実行の通知 ----------------------------------------------------

reset_state; days_ago 4 > "$WORK/state/last-run"; run_dc DISK_CLEANUP_HOUR=14
check "時間帯外でも、4 日走っていなければ通知する" 'notice | "$GREP" -q "ディスク掃除が 4 日走っていません"' "notice: $(notice) / log: $(cat "$WORK/log" 2>/dev/null)"
check "未実行の通知の経路では prune を呼ばない" '! called "^(uv|pnpm|brew|docker)"' "calls: $(cat "$WORK/calls")"
check "未実行の通知を出したら last-notify を書く" '[ "$(cat "$WORK/state/last-notify" 2>/dev/null)" = "$(date +%F)" ]'
check "未実行の通知の経路では last-run を書かない" '[ "$(cat "$WORK/state/last-run")" = "$(days_ago 4)" ]'
: > "$WORK/calls"; run_dc DISK_CLEANUP_HOUR=15
check "未実行の通知は同じ日に 2 回出さない" '! called "^osascript"' "calls: $(cat "$WORK/calls")"

reset_state; days_ago 2 > "$WORK/state/last-run"; run_dc DISK_CLEANUP_HOUR=14
check "2 日しか空いていなければ通知しない" '[ ! -s "$WORK/calls" ]' "calls: $(cat "$WORK/calls")"

# 起点の日付が壊れていたら、通知しない側に倒す（毎時の起動のたびに通知が出ないよう）
reset_state; echo "garbage" > "$WORK/state/last-run"; run_dc DISK_CLEANUP_HOUR=14
check "起点の日付を読めなければ通知せず、ログに残す" '[ ! -s "$WORK/calls" ] && logged "skip 未実行の判定"' "calls: $(cat "$WORK/calls") / log: $(cat "$WORK/log" 2>/dev/null)"

reset_state; days_ago 4 > "$WORK/state/first-seen"; run_dc DISK_CLEANUP_HOUR=14
check "一度も夜に走っていなくても、first-seen から 4 日なら通知する" 'notice | "$GREP" -q "ディスク掃除が 4 日走っていません"' "notice: $(notice)"

reset_state; run_dc DISK_CLEANUP_HOUR=14
check "初回の時間帯外は通知せず、first-seen に今日を書く" '[ ! -s "$WORK/calls" ] && [ "$(cat "$WORK/state/first-seen" 2>/dev/null)" = "$(date +%F)" ]' "calls: $(cat "$WORK/calls")"

reset_state; date +%F > "$WORK/state/first-seen"; run_dc DISK_CLEANUP_HOUR=14
check "first-seen が今日なら通知しない" '[ ! -s "$WORK/calls" ]' "calls: $(cat "$WORK/calls")"

# --- ログ --------------------------------------------------------------------

run_case
check "前後の空き容量をログに残す" 'logged "空き"' "log: $(cat "$WORK/log" 2>/dev/null)"

reset_state; head -c 2000 /dev/zero | tr '\0' x > "$WORK/log"; run_dc DISK_CLEANUP_LOG_MAX_BYTES=1000
check "ログが閾値を超えたら LOG.1 に 1 世代だけ移す" '[ "$(wc -c < "$WORK/log.1" | tr -d " ")" = 2000 ] && logged "start"' "log.1: $(wc -c < "$WORK/log.1" 2>/dev/null)"
check "新しいログは閾値より小さい" '[ "$(wc -c < "$WORK/log" | tr -d " ")" -lt 1000 ]'
rm -f "$WORK/log.1"

echo
echo "pass: $pass_count / fail: $fail_count"
[ "$fail_count" -eq 0 ]
