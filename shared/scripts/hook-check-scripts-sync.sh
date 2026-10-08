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

# 「scripts が 1 件も無い」＝初回 install 前なので静かに終わる。
# 「scripts はあるが .installed-from が無い」＝旧版からの移行途中で出自が追えない状態。
# 両者を区別せず一律 exit 0 にすると、検知したい後者が無警告で通る
if [ ! -f "$ORIGIN" ]; then
    if ls "$INSTALLED"/*.sh >/dev/null 2>&1; then
        jq -n '{
          hookSpecificOutput: {
            hookEventName: "SessionStart",
            additionalContext: "⚠️ [scripts 出自不明] ~/.claude/scripts/ にスクリプトはありますが .installed-from がありません。どのチェックアウトから install されたか追えないため、メインチェックアウトで `./setup.sh install` を実行してください。"
          }
        }' 2>/dev/null || true
    fi
    exit 0
fi

IFS=$'\t' read -r repo_dir _branch _sha < "$ORIGIN" || exit 0
# install 元のチェックアウトが shared/ 移行前の古いブランチにある間は shared/scripts が無く、
# claude/scripts が実ディレクトリとしてある。shared/scripts を優先して両方を探す。
# どちらも解決できないと次行で黙って終わり、未同期の警告が出なくなる
if [ -d "${repo_dir}/shared/scripts" ]; then
    REPO_SCRIPTS="${repo_dir}/shared/scripts"
else
    REPO_SCRIPTS="${repo_dir}/claude/scripts"
fi
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
    elif [ ! -x "$target" ]; then
        stale+=("${name} (実行ビットなし — 実行すると exit 126)")
    fi
done

# 逆方向の走査。repo 起点のループでは「repo から削除されたのに残っているファイル」が見えない。
# verify-skills.sh の check 4 は逆走査を持つのに、自動で走る本 hook が欠いていると
# 最も検出力が低いのが最も頻繁に走る経路、という最悪の配分になる
for installed in "$INSTALLED"/*.sh "$INSTALLED"/*.py; do
    [ -e "$installed" ] || [ -L "$installed" ] || continue
    name=$(basename "$installed")
    [ -f "$REPO_SCRIPTS/$name" ] && continue
    if [ -L "$installed" ] && [ ! -e "$installed" ]; then
        stale+=("${name} (orphan / dangling — 実行すると exit 127)")
    else
        stale+=("${name} (orphan)")
    fi
done

[ ${#stale[@]} -eq 0 ] && exit 0

# bash 3.2 では set -u 下で空配列を "${arr[@]}" 展開すると unbound variable となり
# exit 127 で終わる（実測）。上のガードで空は弾いているが、ガードを消しただけで
# 「常に exit 0」の契約が破れるのは危うい。${arr[@]+...} で構造的に保証する
list=$(printf '%s, ' ${stale[@]+"${stale[@]}"})
list=${list%, }

jq -n --arg list "$list" --arg n "${#stale[@]}" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: ("⚠️ [scripts 未同期] \($n) 件が repo と一致していません: \($list)。hook は失敗せず古いスクリプトで動き続けるため、メインチェックアウトで `./setup.sh install` を実行してください。")
  }
}' 2>/dev/null || true

exit 0
