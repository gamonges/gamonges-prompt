#!/bin/bash
#
# hook-check-scripts-sync.sh
# --------------------------
# SessionStart hook。~/.claude/scripts/ が repo と同期しているかを cmp で照合し、
# ズレていればメインエージェントに通知する。
#
# scripts は実体コピー方式のため「編集・pull したが ./setup.sh install を忘れた」状態が
# 静かに成立する（hook は失敗せず古いスクリプトで動き続ける）。人間が忘れることを前提に
# hook を強化した以上、install の再実行だけを人間の記憶に委ねるのは一貫しない。
#
# 設計上の制約:
# - 差分が無ければ何も出力しない。毎セッション鳴る通知は無視されるようになるため
# - 通知であってガードレールではないので、内部で何が失敗しても常に exit 0 で終わる
# - 本スクリプト自身も同期対象なので、古いままだと検知も古くなる（初回 install 以降は機能する）
#
# 使い方: settings.json の SessionStart hook から起動される

set -uo pipefail

INSTALLED="$HOME/.claude/scripts"
ORIGIN="$INSTALLED/.installed-from"

# install 元が記録されていなければ何もしない（初回 install 前 / 旧版からの移行途中）
[ -f "$ORIGIN" ] || exit 0

IFS=$'\t' read -r repo_dir _branch _sha < "$ORIGIN" || exit 0
REPO_SCRIPTS="${repo_dir}/claude/scripts"
[ -d "$REPO_SCRIPTS" ] || exit 0

stale=()
for script in "$REPO_SCRIPTS"/*.sh "$REPO_SCRIPTS"/*.py; do
    [ -f "$script" ] || continue
    name=$(basename "$script")
    target="$INSTALLED/$name"

    if [ -L "$target" ]; then
        stale+=("${name} (旧形式の symlink)")
    elif [ ! -f "$target" ]; then
        stale+=("${name} (未インストール)")
    elif ! cmp -s "$script" "$target"; then
        stale+=("${name} (差分あり)")
    fi
done

[ ${#stale[@]} -eq 0 ] && exit 0

list=$(printf '%s, ' "${stale[@]}")
list=${list%, }

jq -n --arg list "$list" --arg n "${#stale[@]}" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: ("⚠️ [scripts 未同期] \($n) 件が repo と一致していません: \($list)。hook は失敗せず古いスクリプトで動き続けるため、メインチェックアウトで `./setup.sh install` を実行してください。")
  }
}' 2>/dev/null || true

exit 0
