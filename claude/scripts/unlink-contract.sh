#!/usr/bin/env bash
# link-contract.sh で差し替えた contract パッケージを registry 解決へ戻す。
# 環境変数は link-contract.sh と同じものを読む（設定の説明はそちらに 1 回だけ置く）。
#
# 手順の順序が本 script の本質:
#   --no-skip-worktree を先に実行しないと、git checkout はその 2 ファイルを復元しない
#   （実測では pathspec エラーで非ゼロ終了する。エラーを握り潰す経路では
#    「復元したつもりで復元されていない」状態がそのまま残る）。

set -euo pipefail

FRONTEND_DIR="${FRONTEND_DIR:-${CLAUDE_CODE_CONTRACT_FRONTEND_DIR:-}}"
CONTRACT_PKG="${CONTRACT_PKG:-${CLAUDE_CODE_CONTRACT_PKG:-}}"
CONTRACT_APP_PKG_JSON="${CONTRACT_APP_PKG_JSON:-${CLAUDE_CODE_CONTRACT_APP_PKG_JSON:-}}"

LOCKFILE="pnpm-lock.yaml"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "usage: unlink-contract.sh  （環境変数の説明は link-contract.sh --help を参照）" >&2
  exit 0
fi

missing=()
[[ -n "$FRONTEND_DIR" ]] || missing+=("FRONTEND_DIR")
[[ -n "$CONTRACT_PKG" ]] || missing+=("CONTRACT_PKG")
[[ -n "$CONTRACT_APP_PKG_JSON" ]] || missing+=("CONTRACT_APP_PKG_JSON")
if (( ${#missing[@]} > 0 )); then
  echo "unlink-contract.sh: 未設定の環境変数: ${missing[*]}" >&2
  echo "  設定の説明は link-contract.sh --help を参照する。" >&2
  exit 1
fi
[[ -d "$FRONTEND_DIR" ]] || { echo "unlink-contract.sh: ディレクトリが存在しない: $FRONTEND_DIR" >&2; exit 1; }

# --- 事前検査: 対象が index に登録されているか ---
# link-contract.sh の存在チェックと対称にする。
# --no-skip-worktree は bit が立っていない tracked file にも exit 0 を返すので、非ゼロになるのは
# 「パスが index に無い」時だけ。つまり設定ミスの兆候であって「解除済み」ではない。
# これを握り潰すと、原因が表示されないまま手順 4 の checkout が pathspec エラーで落ちる
for path in "$CONTRACT_APP_PKG_JSON" "$LOCKFILE"; do
  if ! git -C "$FRONTEND_DIR" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
    echo "unlink-contract.sh: git の管理下に無い: $FRONTEND_DIR/$path" >&2
    echo "  CONTRACT_APP_PKG_JSON / FRONTEND_DIR の設定を確認する（FRONTEND_DIR からの相対パスで指定する）。" >&2
    exit 1
  fi
done

# --- 手順 1: skip-worktree の解除（必ず最初） ---
# 立ったまま git checkout すると復元されない（実測: pathspec エラーで非ゼロ終了）。
# 事前検査を通った後にここが失敗するのは想定外なので、握り潰さず落とす
git -C "$FRONTEND_DIR" update-index --no-skip-worktree "$CONTRACT_APP_PKG_JSON" "$LOCKFILE"
echo "==> skip-worktree を解除した（立っていなかった場合も no-op で成功する）"

# --- 手順 2: 差分の表示 ---
# 解除して初めて差分が見える。link 中に生じた「正当な」lockfile 変更が混ざっていないかを
# 確認できる唯一の機会。次の手順の checkout はそれごと破棄する
echo "==> 復元前の差分（link 差分以外が混ざっていないか確認する）:"
git -C "$FRONTEND_DIR" --no-pager diff --stat -- "$CONTRACT_APP_PKG_JSON" "$LOCKFILE" || true
git -C "$FRONTEND_DIR" --no-pager diff -- "$CONTRACT_APP_PKG_JSON" || true

# --- 手順 3: link の解除 ---
# 失敗しても続行する。package.json と lockfile の正本の復元手段は手順 4-5 であり、
# pnpm unlink は node_modules 側の後始末に過ぎない
APP_DIR="$FRONTEND_DIR/$(dirname "$CONTRACT_APP_PKG_JSON")"
echo "==> pnpm unlink: $CONTRACT_PKG"
if ! ( cd "$APP_DIR" && pnpm unlink "$CONTRACT_PKG" ); then
  echo "WARN: pnpm unlink が失敗した。手順 4-5（checkout + install）で復元を続行する" >&2
fi

# --- 手順 4: exact pin と lockfile の復元 ---
# ローカルとリリース済みで version が食い違うため、link すると差分は必ず出る
echo "==> git checkout で復元"
git -C "$FRONTEND_DIR" checkout -- "$CONTRACT_APP_PKG_JSON" "$LOCKFILE"

# --- 手順 5: 依存の整合 ---
echo "==> pnpm install --frozen-lockfile"
( cd "$FRONTEND_DIR" && pnpm install --frozen-lockfile )

# --- 手順 6: 復元されたことを script 自身が assert する ---
# 人が目視を忘れても落ちるようにする
failed=0

remaining=$(git -C "$FRONTEND_DIR" status --porcelain -- "$CONTRACT_APP_PKG_JSON" "$LOCKFILE")
if [[ -n "$remaining" ]]; then
  echo "NG: 対象ファイルに変更が残っている:" >&2
  echo "$remaining" >&2
  failed=1
fi

# clean であることは復元の証明にならない。link: 版が一度 commit されていると checkout は
# HEAD のその内容を戻すため、working tree は clean のまま link: が残る。内容そのものを見る
# （誤コミット防止 hook をすり抜けた場合の最後の検知機会）
local_link=$(grep -nE '"[^"]+"[[:space:]]*:[[:space:]]*"(link:|file:)' "$FRONTEND_DIR/$CONTRACT_APP_PKG_JSON" || true)
if [[ -n "$local_link" ]]; then
  echo "NG: 復元後の $CONTRACT_APP_PKG_JSON に link: / file: の依存宣言が残っている:" >&2
  echo "$local_link" >&2
  echo "  link: 版が commit 済みの可能性がある（checkout は HEAD の内容を戻すので clean になる）。" >&2
  failed=1
fi

hidden=$(git -C "$FRONTEND_DIR" ls-files -v -- "$CONTRACT_APP_PKG_JSON" "$LOCKFILE" | grep '^S' || true)
if [[ -n "$hidden" ]]; then
  echo "NG: skip-worktree が残っている:" >&2
  echo "$hidden" >&2
  failed=1
fi

# 対象外のファイルは落とさずに知らせる（link と無関係な作業中の変更で失敗させない）
others=$(git -C "$FRONTEND_DIR" status --porcelain | grep -v -e "$CONTRACT_APP_PKG_JSON" -e "$LOCKFILE" || true)
if [[ -n "$others" ]]; then
  echo "INFO: 対象外のファイルに変更が残っている（link とは無関係のはず）:"
  echo "$others"
fi

other_hidden=$(git -C "$FRONTEND_DIR" ls-files -v | grep '^S' || true)
if [[ -n "$other_hidden" ]]; then
  echo "INFO: 他のファイルに skip-worktree が立っている:"
  echo "$other_hidden"
fi

if (( failed == 1 )); then
  echo "unlink-contract.sh: 復元に失敗した。上記を手で解消する。" >&2
  exit 1
fi

echo "unlink 完了。対象ファイルは clean、skip-worktree も残っていない。"
