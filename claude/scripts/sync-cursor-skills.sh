#!/bin/bash
# sync-cursor-skills.sh
# .cursor/skills/ のスキルを .claude/skills/ にシンボリックリンクで参照可能にする
# 各リポジトリのルートで実行する。冪等。

set -euo pipefail

CURSOR_SKILLS=".cursor/skills"
CLAUDE_SKILLS=".claude/skills"

if [ ! -d "$CURSOR_SKILLS" ]; then
  echo "No .cursor/skills/ found. Skipping." >&2
  exit 0
fi

mkdir -p "$CLAUDE_SKILLS"

created=0
skipped=0
cleaned=0

for dir in "$CURSOR_SKILLS"/*/; do
  [ -d "$dir" ] || continue
  name=$(basename "$dir")

  if [ -f "$dir/SKILL.md" ]; then
    # 通常スキル: SKILL.md があるディレクトリをリンク
    link="$CLAUDE_SKILLS/$name"
    target="../../.cursor/skills/$name"
    if [ -d "$link" ] && [ ! -L "$link" ]; then
      # 独自スキル（実ディレクトリ）はスキップ
      ((skipped++))
      continue
    fi
    [ -L "$link" ] && rm "$link"
    ln -s "$target" "$link"
    ((created++))
  else
    # egov パターン: サブディレクトリに SKILL.md があればフラット化リンク
    for subdir in "$dir"*/; do
      [ -d "$subdir" ] || continue
      if [ -f "$subdir/SKILL.md" ]; then
        subname=$(basename "$subdir")
        link="$CLAUDE_SKILLS/${name}-${subname}"
        target="../../.cursor/skills/$name/$subname"
        [ -L "$link" ] && rm "$link"
        ln -s "$target" "$link"
        ((created++))
      fi
    done
  fi
done

# デッドリンクのクリーンアップ（.cursor/skills を指すもののみ）
for link in "$CLAUDE_SKILLS"/*/; do
  [ -L "${link%/}" ] || continue
  target=$(readlink "${link%/}")
  if [[ "$target" == *".cursor/skills"* ]] && [ ! -e "${link%/}" ]; then
    rm "${link%/}"
    ((cleaned++))
  fi
done

echo "sync-cursor-skills: created=$created skipped=$skipped cleaned=$cleaned" >&2
