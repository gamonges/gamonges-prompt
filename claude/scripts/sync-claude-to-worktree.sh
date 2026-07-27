#!/bin/bash
# sync-claude-to-worktree.sh
# worktree内で .claude/ が存在しない場合、メインのworktreeからコピーする
# UserPromptSubmit hook から呼ばれる（初回プロンプト時に1度だけ実効）

set -euo pipefail

# 現在のディレクトリがgit worktreeかどうか判定
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  exit 0
fi

MAIN_WORKTREE=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
CURRENT_DIR=$(pwd -P)

# メインworktreeと同じなら何もしない
if [ "$CURRENT_DIR" = "$MAIN_WORKTREE" ]; then
  exit 0
fi

# cwd が worktree のルートでなければ（＝リポジトリのサブディレクトリなら）何もしない。
# git worktree list はサブディレクトリでもメインルートを返すため、cwd!=MAIN だけでは
# 「サブディレクトリ起動」と「linked worktree」を区別できず .claude が誤コピーされる。
# 現worktreeのルート(show-toplevel)と cwd が一致する時だけ＝本物の worktree ルートに限定する。
if [ "$CURRENT_DIR" != "$(git rev-parse --show-toplevel 2>/dev/null)" ]; then
  exit 0
fi

# CLAUDE.md が既にあれば同期済みとみなす
if [ -f ".claude/CLAUDE.md" ]; then
  exit 0
fi

# メインworktreeに .claude/ がなければ何もしない
if [ ! -d "$MAIN_WORKTREE/.claude" ]; then
  exit 0
fi

# .claude/ をコピー（worktrees/ と settings.local.json は除外）
rsync -a \
  --exclude='worktrees/' \
  --exclude='settings.local.json' \
  "$MAIN_WORKTREE/.claude/" ".claude/"

echo "Synced .claude/ from main worktree: $MAIN_WORKTREE" >&2

# .cursor/skills → .claude/skills のシンボリックリンクを再作成
# (rsync でコピーされたリンクは元のworktreeの .cursor/ を指しておりデッドリンクになる)
SYNC_SCRIPT="$HOME/.claude/scripts/sync-cursor-skills.sh"
if [ -x "$SYNC_SCRIPT" ] || [ -L "$SYNC_SCRIPT" ]; then
  bash "$SYNC_SCRIPT"
fi
