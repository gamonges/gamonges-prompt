#!/bin/bash
# sync-claude-to-worktree.sh
# linked worktree に、メインの worktree の .claude/ にしか無い未追跡の設定（ローカルの CLAUDE.md 等）を運ぶ。
# 追跡ファイルは worktree のブランチが正なので触らない。運ぶのはメインにしか無い未追跡の設定だけで、
# worktree に既にあるものも上書きしない
# UserPromptSubmit hook から毎プロンプト呼ばれる（同期済みなら早く抜ける）

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

# worktree に CLAUDE.md があれば同期済みとみなす（2 回目以降のプロンプトを速く抜ける）
if [ -f ".claude/CLAUDE.md" ]; then
  exit 0
fi

# メインworktreeに .claude/ がなければ何もしない
if [ ! -d "$MAIN_WORKTREE/.claude" ]; then
  exit 0
fi

# メインの .claude/ の未追跡ファイルを列挙する。gitignore の対象（ローカルの CLAUDE.md 等）も運ぶので
# --exclude-standard は付けない。core.quotePath=false は非 ASCII のパスを "\343..." と引用させないため
# （引用されたパスは --files-from で存在しないパスになり、黙って写らない）
LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
git -c core.quotePath=false -C "$MAIN_WORKTREE" ls-files --others -- .claude |
  while IFS= read -r path; do
    case "$path" in
    # 改行・タブ・" ・\ を含むパスは false でも引用が残る。対象外として知らせる
    '"'*)
      echo "sync-claude-to-worktree: 引用が残るパスは対象外のため飛ばします: $path" >&2
      continue
      ;;
    .claude/worktrees/* | */settings.local.json) continue ;;
    esac
    printf '%s\n' "$path"
  done >"$LIST"

if [ -s "$LIST" ]; then
  # --ignore-existing: メインでは未追跡でも、worktree のブランチで追跡しているもの（ブランチで足したもの）を守る
  rsync -a --ignore-existing --files-from="$LIST" "$MAIN_WORKTREE/" ./
  echo "Synced untracked .claude/ files from main worktree: $MAIN_WORKTREE" >&2
fi

# worktree の .cursor/skills/ から .claude/skills/ へのリンクを作る（冪等）。
# リンクが要るかは worktree の .cursor/skills/ で決まり、写したかどうかとは関係が無いので、写す物が無くても呼ぶ
SYNC_SCRIPT="$HOME/.claude/scripts/sync-cursor-skills.sh"
# scripts は実体コピー方式なので symlink は作られない。-L を許容すると dangling symlink を
# 実行しようとして exit 127 になる
if [ -d ".cursor/skills" ] && [ -x "$SYNC_SCRIPT" ]; then
  bash "$SYNC_SCRIPT"
fi
