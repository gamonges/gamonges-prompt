#!/usr/bin/env bash
# 毎晩のディスク掃除。launchd（setup.sh install が配置する LaunchAgent）が 1〜7 時の毎時に起動する。
#
# 消すのは「消しても次に使う時に自動で取り直せるもの」だけ。判断が要るもの（空き不足・マージ済み
# worktree）は通知に留め、取り返せないもの（Docker のボリューム・uv cache clean・worktree）には触らない。
# 自動化した掃除が取り返せないものまで消すと、毎晩同じ事故を起こしうるため。
#
# 時間帯: launchd はスリープで逃した起動を起床時に 1 回だけ発火するので、起動時刻ではなく
# 「今が 1:00〜7:59 か」で判定する。夜通し寝ていた日は飛ばす（日中に重い prune を走らせない）。
#
# 環境変数（テストと手動実行用）:
#   DISK_CLEANUP_FORCE=1          時間帯と「今日は実行済み」を無視する
#   DISK_CLEANUP_HOUR             現在時刻（時）の上書き
#   DISK_CLEANUP_THRESHOLD_GB     通知する空きの境目（既定 50）
#   DISK_CLEANUP_STATE_DIR / DISK_CLEANUP_LOG / DISK_CLEANUP_CACHES_DIR / DISK_CLEANUP_WORKTREE_ROOT
#
# 手動実行: DISK_CLEANUP_FORCE=1 ~/.claude/scripts/disk-cleanup.sh

set -uo pipefail

STATE_DIR="${DISK_CLEANUP_STATE_DIR:-$HOME/.local/state/disk-cleanup}"
LOG="${DISK_CLEANUP_LOG:-$HOME/Library/Logs/disk-cleanup.log}"
CACHES_DIR="${DISK_CLEANUP_CACHES_DIR:-$HOME/Library/Caches}"
WORKTREE_ROOT="${DISK_CLEANUP_WORKTREE_ROOT:-$HOME/orca/workspaces}"
THRESHOLD_GB="${DISK_CLEANUP_THRESHOLD_GB:-50}"
# Docker はイメージの最終使用日時を持たない。「どのコンテナからも参照されず、作成から 7 日以上」で近似する
DOCKER_UNTIL="168h"

today="$(date +%F)"
hour=$((10#${DISK_CLEANUP_HOUR:-$(date +%H)}))

if [ "${DISK_CLEANUP_FORCE:-0}" != 1 ]; then
    [ "$hour" -ge 1 ] && [ "$hour" -lt 8 ] || exit 0
    [ "$(cat "$STATE_DIR/last-run" 2>/dev/null)" = "$today" ] && exit 0
fi

mkdir -p "$STATE_DIR" "$(dirname "$LOG")"
# 先にスタンプを書く。途中で落ちても同じ晩に何度も重い prune を繰り返さないため
echo "$today" > "$STATE_DIR/last-run"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

free_gb() {
    local target=/System/Volumes/Data
    [ -d "$target" ] || target=/
    df -k "$target" | awk 'NR==2 { print int($4 / 1024 / 1024) }'
}

# コマンドが無ければ飛ばし、失敗しても残りを続ける
step() {
    local name="$1"; shift
    if ! command -v "$1" >/dev/null 2>&1; then
        log "skip $name（$1 が無い）"
        return 0
    fi
    "$@" >> "$LOG" 2>&1
    log "done $name (exit $?)"
}

before="$(free_gb)"
log "start 空き ${before}GB"

step uv uv cache prune
(cd "$HOME" && step pnpm pnpm store prune)
HOMEBREW_NO_AUTO_UPDATE=1 step brew brew cleanup -s

# Docker は起動していなければ飛ばす（起動はしない）
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    step docker-image docker image prune -a -f --filter "until=$DOCKER_UNTIL"
    step docker-builder docker builder prune -f --filter "until=$DOCKER_UNTIL"
else
    log "skip docker（起動していない）"
fi

# アプリの自動更新（Sparkle・*-updater）がダウンロードした更新パッケージの残り
for d in "$CACHES_DIR"/*/org.sparkle-project.Sparkle "$CACHES_DIR"/*-updater; do
    [ -d "$d" ] || continue
    rm -rf "$d" && log "removed $d"
done

after="$(free_gb)"
log "end 空き ${after}GB（${before}GB から）"

# --- 通知だけするもの ---------------------------------------------------------

# マージ済み PR のブランチを checkout したままの worktree を数える（消すのは /worktree-cleanup）
count_merged_worktrees() {
    local total=0 repo wt first merged b
    for repo in "$WORKTREE_ROOT"/*/; do
        first=""
        for wt in "$repo"*/; do [ -e "$wt.git" ] && { first="$wt"; break; }; done
        [ -n "$first" ] || continue
        merged="$(cd "$first" && gh pr list --author @me --state merged --limit 300 --json headRefName 2>/dev/null \
            | grep -o '"headRefName":"[^"]*"' | sed 's/.*:"//; s/"$//')" || continue
        for wt in "$repo"*/; do
            [ -e "$wt.git" ] || continue
            b="$(git -C "$wt" branch --show-current 2>/dev/null)"
            case "$b" in ""|main|master|develop) continue ;; esac
            printf '%s\n' "$merged" | grep -qxF "$b" && total=$((total + 1))
        done
    done
    echo "$total"
}

messages=()
[ "$after" -lt "$THRESHOLD_GB" ] && messages+=("空き ${after}GB（${THRESHOLD_GB}GB 未満）")
if command -v gh >/dev/null 2>&1 && [ -d "$WORKTREE_ROOT" ]; then
    merged_count="$(count_merged_worktrees)"
    log "マージ済み worktree ${merged_count} 本"
    [ "$merged_count" -gt 0 ] && messages+=("マージ済み worktree ${merged_count} 本 → /worktree-cleanup")
fi

if [ "${#messages[@]}" -gt 0 ]; then
    # IFS で区切ると多バイト文字を区切りに使えない（bash は IFS の先頭 1 バイトで結合する）
    body="${messages[0]}"
    for m in "${messages[@]:1}"; do body="$body / $m"; done
    log "notify $body"
    osascript -e "display notification \"$body\" with title \"ディスク掃除\"" >/dev/null 2>&1
fi
exit 0
