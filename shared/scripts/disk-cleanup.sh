#!/usr/bin/env bash
# 毎晩のディスク掃除。launchd（setup.sh install が配置する LaunchAgent）が 1〜7 時の毎時に起動する。
#
# 消すのは「消しても次に使う時に自動で取り直せるもの」と「戻す必要がまず無いもの（brew の旧バージョン）」
# だけ。判断が要るもの（空き不足・マージ済み worktree）は通知に留め、取り返せないもの（Docker のボリューム・
# レジストリに無いイメージ・uv cache clean・worktree）には触らない。自動化した掃除が取り返せないものまで
# 消すと、毎晩同じ事故を起こしうるため。
#
# 時間帯: launchd はスリープで逃した起動を起床時に 1 回だけ発火するので、起動時刻ではなく
# 「今が 1:00〜7:59 か」で判定する。時間帯外の起動では prune しない（日中に重い prune を走らせない）。
# ただし最後に走った日（無ければ最初に起動した日）から STALE_DAYS 日以上たっていれば、そのことを通知する。
#
# 止める: $STATE_DIR/disabled があれば何もしない（setup.sh install し直しても止まったまま）。
#
# 環境変数（テストと手動実行用）:
#   DISK_CLEANUP_FORCE=1           時間帯と「今日は実行済み」を無視する（disabled は無視しない）
#   DISK_CLEANUP_HOUR              現在時刻（時）の上書き
#   DISK_CLEANUP_THRESHOLD_GB      通知する空きの境目（既定 50）
#   DISK_CLEANUP_STEP_TIMEOUT      1 段の上限の秒数（既定 1800）
#   DISK_CLEANUP_STALE_DAYS        未実行を通知するまでの日数（既定 3）
#   DISK_CLEANUP_LOG_MAX_BYTES     ログを 1 世代ずらす大きさ（既定 1048576）
#   DISK_CLEANUP_STATE_DIR / DISK_CLEANUP_LOG / DISK_CLEANUP_CACHES_DIR / DISK_CLEANUP_WORKTREE_ROOT
#
# 手動実行: DISK_CLEANUP_FORCE=1 ~/.claude/scripts/disk-cleanup.sh

set -uo pipefail

STATE_DIR="${DISK_CLEANUP_STATE_DIR:-$HOME/.local/state/disk-cleanup}"
LOG="${DISK_CLEANUP_LOG:-$HOME/Library/Logs/disk-cleanup.log}"
CACHES_DIR="${DISK_CLEANUP_CACHES_DIR:-$HOME/Library/Caches}"
WORKTREE_ROOT="${DISK_CLEANUP_WORKTREE_ROOT:-$HOME/orca/workspaces}"
THRESHOLD_GB="${DISK_CLEANUP_THRESHOLD_GB:-50}"
STEP_TIMEOUT="${DISK_CLEANUP_STEP_TIMEOUT:-1800}"
STALE_DAYS="${DISK_CLEANUP_STALE_DAYS:-3}"
LOG_MAX_BYTES="${DISK_CLEANUP_LOG_MAX_BYTES:-1048576}"
DOCKER_MAX_AGE_DAYS=7
DOCKER_UNTIL="$((DOCKER_MAX_AGE_DAYS * 24))h"

today="$(date +%F)"
# date +%H は 08・09 を返す。10# が無いと 8 進数として読んで落ちる
hour=$((10#${DISK_CLEANUP_HOUR:-$(date +%H)}))

mkdir -p "$STATE_DIR" "$(dirname "$LOG")"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# 1 世代だけ残す。prune の出力を毎晩追記するので、放っておくと増え続ける
size="$(stat -f %z "$LOG" 2>/dev/null || stat -c %s "$LOG" 2>/dev/null || echo 0)"
[ "$size" -gt "$LOG_MAX_BYTES" ] 2>/dev/null && mv -f "$LOG" "$LOG.1"

if [ -e "$STATE_DIR/disabled" ]; then
    # 毎時の起動のたびに 1 行ずつ増えないよう、ログはその日の最初の 1 回だけ
    if [ "$(cat "$STATE_DIR/last-disabled-log" 2>/dev/null)" != "$today" ]; then
        log "skip disabled（$STATE_DIR/disabled があるので止めている）"
        echo "$today" > "$STATE_DIR/last-disabled-log"
    fi
    exit 0
fi

# 未実行の日数の起点。一度も時間帯内に走っていない（毎晩 Mac を閉じて寝かせる）利用者にも通知を届けるため、
# last-run が無ければこれを起点にする。初回は今日にして、install の直後の日中に通知が出ないようにする
[ -e "$STATE_DIR/first-seen" ] || echo "$today" > "$STATE_DIR/first-seen"

free_gb() {
    local target=/System/Volumes/Data
    [ -d "$target" ] || target=/
    df -k "$target" | awk 'NR==2 { print int($4 / 1024 / 1024) }'
}

# with_timeout <秒> <cmd…>: 秒数を超えたら打ち切り、124 を返す。macOS 標準には timeout が無い。
# 1 段がハングすると以後の段と通知が止まるので、外部コマンドはこれを通す。
# 本体を set -m で別のプロセスグループにし、グループごと止める（シェル関数や brew の子孫まで止めるため。
# 起動したプロセスだけを kill すると、その中で走っている docker や ruby が残る）
with_timeout() {
    local secs="$1"; shift
    local mark="$STATE_DIR/.timeout.$$.$RANDOM" pid wpid rc
    rm -f "$mark"
    set -m
    # stdin は切る。端末から手動で流したとき、別のプロセスグループから端末を読むと SIGTTIN で止まるため
    "$@" < /dev/null &
    pid=$!
    ( sleep "$secs"; : > "$mark"; kill -TERM -- -"$pid" 2>/dev/null; sleep 5; kill -KILL -- -"$pid" 2>/dev/null ) &
    wpid=$!
    set +m
    wait "$pid"
    rc=$?
    # グループで止められない（job control が効いていない）ときは pid で止める。止めないと、監視側の sleep が
    # 秒数（既定 1800）を使い切るまで wait が戻らない
    kill -TERM -- -"$wpid" 2>/dev/null || kill -TERM "$wpid" 2>/dev/null
    wait "$wpid" 2>/dev/null
    if [ -e "$mark" ]; then
        rm -f "$mark"
        return 124
    fi
    return "$rc"
}

# 日付（%F）を、その日の正午の epoch 秒にする。正午にするのは、夏時間の切り替わりで 1 日が 23・25 時間に
# なっても、日数の割り算がずれないため
date_epoch() {
    date -j -f '%F %H:%M:%S' "$1 12:00:00" +%s 2>/dev/null || date -d "$1 12:00:00" +%s 2>/dev/null
}

messages=()
notify() {
    [ "${#messages[@]}" -gt 0 ] || return 0
    # IFS で区切ると多バイト文字を区切りに使えない（bash は IFS の先頭 1 バイトで結合する）
    local body="${messages[0]}" m rc
    for m in "${messages[@]:1}"; do body="$body / $m"; done
    # 本文は短く保ち（長いと通知の表示で切れる）、見る先は subtitle で示す
    osascript -e "display notification \"$body\" with title \"ディスク掃除\" subtitle \"ログ: ${LOG/#$HOME/~}\"" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = 0 ]; then
        log "notify sent (exit 0): $body"
    else
        log "notify failed (exit $rc): $body"
    fi
}

add_free_message() {
    local free="$1"
    [ -n "$free" ] && [ "$free" -lt "$THRESHOLD_GB" ] 2>/dev/null && messages+=("空き ${free}GB（${THRESHOLD_GB}GB 未満）")
}

# 時間帯外の起動。prune はしない。長く走っていなければ、そのことだけを 1 日 1 回通知する
notify_if_stale() {
    local base base_epoch now_epoch days
    base="$(cat "$STATE_DIR/last-run" 2>/dev/null)"
    [ -n "$base" ] || base="$(cat "$STATE_DIR/first-seen" 2>/dev/null)"
    if ! base_epoch="$(date_epoch "$base")" || ! now_epoch="$(date_epoch "$today")"; then
        log "skip 未実行の判定（日付を読めない: '$base'）"
        return 0
    fi
    days=$(( (now_epoch - base_epoch + 43200) / 86400 ))
    [ "$days" -ge "$STALE_DAYS" ] || return 0
    [ "$(cat "$STATE_DIR/last-notify" 2>/dev/null)" = "$today" ] && return 0
    echo "$today" > "$STATE_DIR/last-notify"
    messages+=("ディスク掃除が ${days} 日走っていません（1〜7 時に起きていない）")
    add_free_message "$(free_gb)"
    notify
}

if [ "${DISK_CLEANUP_FORCE:-0}" != 1 ]; then
    if [ "$hour" -lt 1 ] || [ "$hour" -ge 8 ]; then
        notify_if_stale
        exit 0
    fi
    [ "$(cat "$STATE_DIR/last-run" 2>/dev/null)" = "$today" ] && exit 0
fi

# 先にスタンプを書く。途中で落ちても同じ晩に何度も重い prune を繰り返さないため
echo "$today" > "$STATE_DIR/last-run"

FAILED_STEPS=()

# コマンドが無ければ飛ばし、失敗・タイムアウトしても残りを続ける。失敗した段は通知に出す
step() {
    local name="$1" rc; shift
    if ! command -v "$1" >/dev/null 2>&1; then
        log "skip ${name}（$1 が無い）"
        return 0
    fi
    with_timeout "$STEP_TIMEOUT" "$@" >> "$LOG" 2>&1
    rc=$?
    if [ "$rc" = 124 ]; then
        log "timeout ${name}（${STEP_TIMEOUT} 秒）"
        FAILED_STEPS+=("$name")
    else
        log "done $name (exit $rc)"
        [ "$rc" = 0 ] || FAILED_STEPS+=("$name")
    fi
}

# Docker のイメージのうち、レジストリ由来（RepoDigests あり）で、どのコンテナ（停止中を含む）からも参照されず、
# 作成から DOCKER_MAX_AGE_DAYS 日以上のものだけを消す。
# `docker image prune --filter until` はイメージの作成時刻で判定し、再取得できるかを見ない。RepoDigests が空の
# イメージ（ローカルでビルドしたもの・commit したもの）はレジストリに無く、消すと戻せない。dangling（タグ無し）も
# 同じで、タグを付けずに commit したイメージが含まれるので、一括の prune は使わない。
# 中間層（classic builder の親の層）は RepoDigests を持たないので、ここで対象から外れる
prune_pulled_images() {
    local cutoff used ids id line created digests tags t removed=0 failed=0 ok
    cutoff="$(date -u -v-"${DOCKER_MAX_AGE_DAYS}"d +%Y-%m-%dT%H:%M:%S 2>/dev/null \
        || date -u -d "${DOCKER_MAX_AGE_DAYS} days ago" +%Y-%m-%dT%H:%M:%S)" || return 1
    # -r: コンテナが 0 件のとき docker inspect を起動しない（GNU の xargs は空の入力でも 1 回起動する）
    used="$(docker ps -aq | xargs -r docker inspect --format '{{.Image}}')" || return 1
    ids="$(docker image ls -a -q --no-trunc | sort -u)" || return 1
    for id in $ids; do
        if ! line="$(docker image inspect --format '{{.Id}}|{{.Created}}|{{len .RepoDigests}}|{{join .RepoTags " "}}' "$id")"; then
            failed=$((failed + 1))
            continue
        fi
        IFS='|' read -r _ created digests tags <<< "$line"
        [[ "${created:0:19}" < "$cutoff" ]] || continue
        [ "${digests:-0}" -gt 0 ] 2>/dev/null || continue
        printf '%s\n' "$used" | grep -qxF "$id" && continue
        # -f は付けない。使用中なら docker が拒むので、上の判定との 2 重の守りになる
        ok=1
        if [ -n "$tags" ]; then
            for t in $tags; do docker image rm "$t" || ok=0; done
        else
            docker image rm "$id" || ok=0
        fi
        if [ "$ok" = 1 ]; then removed=$((removed + 1)); else failed=$((failed + 1)); fi
    done
    log "docker-images 消した ${removed} 件・失敗 ${failed} 件"
    [ "$failed" = 0 ]
}

before="$(free_gb)"
log "start 空き ${before}GB"

step uv uv cache prune
# launchd が与える cwd に依存せず、どこかの workspace の設定を拾わないよう、HOME で流す
step pnpm pnpm --dir "$HOME" store prune
# -s はダウンロードのキャッシュも消す。旧バージョンの keg も消える（旧版には戻せない）
HOMEBREW_NO_AUTO_UPDATE=1 step brew brew cleanup -s

# Docker は起動していなければ飛ばす（起動はしない）。起動していないのは失敗に数えない
if command -v docker >/dev/null 2>&1 && with_timeout 30 docker info >/dev/null 2>&1; then
    step docker-images prune_pulled_images
    step docker-builder docker builder prune -f --filter "until=$DOCKER_UNTIL"
else
    log "skip docker（起動していない、または 30 秒で応答しない）"
fi

# アプリの自動更新（Sparkle・*-updater）がダウンロードした更新パッケージの残り。
# インストールの途中で消すと更新が壊れうるので、配下も含めて直近 24 時間に触られたものは残す
# （最上位の mtime は、配下の既存ファイルへの書き込みでは変わらない）
updater_failed=0
for d in "$CACHES_DIR"/*/org.sparkle-project.Sparkle "$CACHES_DIR"/*-updater; do
    [ -d "$d" ] || continue
    if ! recent="$(find "$d" -mmin -1440 -print -quit 2>/dev/null)"; then
        log "skip ${d}（更新時刻を確かめられない）"
        continue
    fi
    if [ -n "$recent" ]; then
        log "skip ${d}（24 時間以内に更新）"
        continue
    fi
    if rm -rf "$d"; then
        log "removed $d"
    else
        log "failed rm $d"
        updater_failed=1
    fi
done
[ "$updater_failed" = 1 ] && FAILED_STEPS+=("updater")

after="$(free_gb)"
log "end 空き ${after}GB（${before}GB から）"

# --- 通知だけするもの ---------------------------------------------------------

# マージ済み PR のブランチを checkout したままの worktree を数える（消すのは /worktree-cleanup）。
# ブランチ名で突き合わせる点と author で絞らない点は /worktree-cleanup の list-merged.sh と同じ。
# list-merged.sh は最新 50 件しか見ないので、本数は一致しないことがある
MERGED_TOTAL=0
MERGED_DETAIL=""
GH_FAILED_REPOS=0
count_merged_worktrees() {
    local repo name wt b n count failed
    for repo in "$WORKTREE_ROOT"/*/; do
        [ -d "$repo" ] || continue
        name="$(basename "$repo")"
        count=0
        failed=0
        for wt in "$repo"*/; do
            [ -e "${wt}.git" ] || continue
            b="$(git -C "$wt" branch --show-current 2>/dev/null)"
            case "$b" in ""|main|master|develop) continue ;; esac
            # 失敗したら、その repo の残りは問い合わせない（ネットワークにつながらない晩に、worktree の本数 × 60 秒
            # かかるのを防ぐ）
            if ! n="$(cd "$wt" && with_timeout 60 gh pr list --head "$b" --state merged --limit 1 --json number --jq length 2>/dev/null)"; then
                failed=1
                break
            fi
            case "$n" in ''|*[!0-9]*) failed=1; break ;; esac
            [ "$n" -gt 0 ] && count=$((count + 1))
        done
        if [ "$failed" = 1 ]; then
            GH_FAILED_REPOS=$((GH_FAILED_REPOS + 1))
            log "skip ${name}（gh で確かめられない）"
        fi
        if [ "$count" -gt 0 ]; then
            MERGED_TOTAL=$((MERGED_TOTAL + count))
            MERGED_DETAIL="${MERGED_DETAIL:+${MERGED_DETAIL}・}$name $count"
        fi
    done
}

add_free_message "$after"
if [ "${#FAILED_STEPS[@]}" -gt 0 ]; then
    failed_list="${FAILED_STEPS[0]}"
    for s in "${FAILED_STEPS[@]:1}"; do failed_list="${failed_list}・$s"; done
    messages+=("失敗: $failed_list")
fi
if command -v gh >/dev/null 2>&1 && [ -d "$WORKTREE_ROOT" ]; then
    count_merged_worktrees
    if [ "$GH_FAILED_REPOS" -gt 0 ]; then
        log "確認できなかった repo ${GH_FAILED_REPOS} 件"
        messages+=("worktree を確認できなかった repo ${GH_FAILED_REPOS} 件")
    fi
    if [ "$MERGED_TOTAL" -gt 0 ]; then
        log "マージ済み worktree ${MERGED_TOTAL} 本（${MERGED_DETAIL}）"
        messages+=("マージ済み worktree ${MERGED_TOTAL} 本（${MERGED_DETAIL}）→ /worktree-cleanup")
    elif [ "$GH_FAILED_REPOS" = 0 ]; then
        log "マージ済み worktree 0 本"
    fi
fi

notify
exit 0
