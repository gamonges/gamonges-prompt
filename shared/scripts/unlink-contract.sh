#!/usr/bin/env bash
# link-contract.sh で差し替えた contract パッケージを registry 解決へ戻す。
# 環境変数は link-contract.sh と同じものを読む（設定の説明はそちらに 1 回だけ置く）。
#
# 手順の順序が本 script の本質:
#   --no-skip-worktree を先に実行しないと、git checkout はその対象を復元しない
#   （実測では pathspec エラーで非ゼロ終了する。エラーを握り潰す経路では
#    「復元したつもりで復元されていない」状態がそのまま残る）。
#
# ガードを下ろしてから復元し終えるまでの窓では trap を張る。この窓で中断すると
# 「link 完了状態から第一ガードだけを剥がした状態」が残り、git add / commit -a / IDE の
# どれからでも巻き込める。手順 3 の pnpm unlink は install を伴って数秒〜数十秒かかるため、
# Ctrl-C も失敗も現実的に起きる。

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

# 保護対象は link-contract.sh と同じ固定リスト（説明はそちらに置く）。
# 状態ファイルで引き継がず両者で同じ計算をするのは、引き継ぎファイル自体が
# 消える / 古くなるという新しい失敗表面を作らないため
GUARDED_PATHS=("$CONTRACT_APP_PKG_JSON" "$LOCKFILE" "package.json" "pnpm-workspace.yaml")

dedupe_in_place() {
  local -a seen=()
  local p q dup
  for p in ${GUARDED_PATHS[@]+"${GUARDED_PATHS[@]}"}; do
    dup=0
    for q in ${seen[@]+"${seen[@]}"}; do
      [[ "$p" == "$q" ]] && { dup=1; break; }
    done
    (( dup == 0 )) && seen+=("$p")
  done
  GUARDED_PATHS=(${seen[@]+"${seen[@]}"})
}
dedupe_in_place

tracked_guarded_paths() {
  local p
  for p in ${GUARDED_PATHS[@]+"${GUARDED_PATHS[@]}"}; do
    if git -C "$FRONTEND_DIR" ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
      printf '%s\n' "$p"
    fi
  done
}

LOCAL_LINK_RE='"[^"]+"[[:space:]]*:[[:space:]]*"(link:|file:)|specifier:[[:space:]]*['"'"'"]?(link:|file:)|['"'"'"]?[^[:space:]'"'"'"]+['"'"'"]?:[[:space:]]*['"'"'"]?(link:|file:)'

# --- 事前検査 1: 対象が index に登録されているか ---
# link-contract.sh の事前検査と対称にする。
# --no-skip-worktree は bit が立っていない tracked file にも exit 0 を返すので、非ゼロになるのは
# 「パスが index に無い」時だけ。つまり設定ミスの兆候であって「解除済み」ではない。
# これを握り潰すと、原因が表示されないまま手順 4 の checkout が pathspec エラーで落ちる
guarded=()
while IFS= read -r one_path; do
  [[ -n "$one_path" ]] && guarded+=("$one_path")
done < <(tracked_guarded_paths)

if (( ${#guarded[@]} == 0 )); then
  echo "unlink-contract.sh: 保護対象が 1 つも git の管理下に無い: ${GUARDED_PATHS[*]}" >&2
  echo "  CONTRACT_APP_PKG_JSON / FRONTEND_DIR の設定を確認する（FRONTEND_DIR からの相対パスで指定する）。" >&2
  exit 1
fi

# --- 事前検査 2: そもそも link されているか ---
# 無条件に checkout すると、link していない repo で走らせたときに作業中の変更を
# 無言で破棄して「完了」と報告する。損失は非可逆なので、痕跡が無ければ何もせず止まる。
# 痕跡は 2 つ: skip-worktree が立っている / 保護対象の内容に link: が残っている
hidden_now=$(git -C "$FRONTEND_DIR" ls-files -v -- ${guarded[@]+"${guarded[@]}"} | grep -c '^S' || true)
link_now=0
for one_path in ${GUARDED_PATHS[@]+"${GUARDED_PATHS[@]}"}; do
  [[ -r "$FRONTEND_DIR/$one_path" ]] || continue
  # grep -q へパイプしない（理由は link-contract.sh の同じ判定に書いてある）
  if [[ "$(grep -cE "$LOCAL_LINK_RE" "$FRONTEND_DIR/$one_path" || true)" != "0" ]]; then
    link_now=1
    break
  fi
done

if [[ "${hidden_now:-0}" -eq 0 && "$link_now" -eq 0 ]]; then
  echo "unlink-contract.sh: link されている痕跡が無い（skip-worktree も link: の依存宣言も見つからない）。" >&2
  echo "  何もせず中断する。無条件に git checkout すると、link と無関係な未コミット変更を" >&2
  echo "  破棄してしまい、それは元に戻せない。" >&2
  echo "  link 中のはずなら CONTRACT_APP_PKG_JSON / FRONTEND_DIR の設定を確認する。" >&2
  exit 1
fi

# --- 手順 1: skip-worktree の解除（必ず最初） ---
# 立ったまま git checkout すると復元されない（実測: pathspec エラーで非ゼロ終了）。
# 事前検査を通った後にここが失敗するのは想定外なので、握り潰さず落とす
git -C "$FRONTEND_DIR" update-index --no-skip-worktree -- ${guarded[@]+"${guarded[@]}"}

# ここから手順 4 の完了までが「ガードが下りていて、まだ復元されていない」窓。
# 中断したらガードを再武装してから死ぬ（復元は諦めるが、誤コミットの経路は閉じ直す）
restored=0
rearm_on_abort() {
  (( restored == 1 )) && return
  echo "" >&2
  echo "unlink-contract.sh: 復元前に中断した。skip-worktree を再度立てる（第一ガードを戻す）。" >&2
  echo "  復元をやり直す:  bash $0" >&2
  git -C "$FRONTEND_DIR" update-index --skip-worktree -- ${guarded[@]+"${guarded[@]}"} 2>/dev/null || true
}
trap rearm_on_abort EXIT INT TERM

echo "==> skip-worktree を解除した（立っていなかった場合も no-op で成功する）: ${guarded[*]}"

# --- 手順 2: 破棄されるものを見せる / 退避する ---
# 解除して初めて差分が見える。link 中に生じた「正当な」変更が混ざっていないかを
# 確認できる唯一の機会で、次の手順の checkout はそれごと破棄する。
#
# 表示だけをベストエフォート（|| true）にして破棄を無条件にすると、「唯一の機会」が
# 無音で飛んだまま非可逆な破棄が走る。lockfile は --stat しか出ないので中身は原理的に
# 見えないままでもある。したがって表示に頼らず、破棄されるものを実体で退避する
BACKUP_DIR="$(mktemp -d)"
echo "==> 復元前の差分（link 差分以外が混ざっていないか確認する）:"
git -C "$FRONTEND_DIR" --no-pager diff --stat -- ${guarded[@]+"${guarded[@]}"} || {
  echo "WARN: 差分を表示できなかった。退避したファイルで内容を確認できる: $BACKUP_DIR" >&2
}
git -C "$FRONTEND_DIR" --no-pager diff -- "$CONTRACT_APP_PKG_JSON" || true

for one_path in ${guarded[@]+"${guarded[@]}"}; do
  if [[ -f "$FRONTEND_DIR/$one_path" ]]; then
    mkdir -p "$BACKUP_DIR/$(dirname "$one_path")"
    cp "$FRONTEND_DIR/$one_path" "$BACKUP_DIR/$one_path"
  fi
done
echo "==> 破棄前の内容を退避した（checkout で失われるものはここにある）: $BACKUP_DIR"

# --- 手順 3: link の解除 ---
# 失敗しても続行する。package.json と lockfile の正本の復元手段は手順 4-5 であり、
# pnpm unlink は node_modules 側の後始末に過ぎない
APP_DIR="$FRONTEND_DIR/$(dirname "$CONTRACT_APP_PKG_JSON")"
echo "==> pnpm unlink: $CONTRACT_PKG"
if ! ( cd "$APP_DIR" && pnpm unlink "$CONTRACT_PKG" ); then
  echo "WARN: pnpm unlink が失敗した。手順 4-5（checkout + install）で復元を続行する" >&2
fi

# --- 手順 4: 保護対象の復元 ---
# ローカルとリリース済みで version が食い違うため、link すると差分は必ず出る
echo "==> git checkout で復元"
git -C "$FRONTEND_DIR" checkout -- ${guarded[@]+"${guarded[@]}"}
restored=1
trap - EXIT INT TERM

# --- 手順 5: 依存の整合 ---
echo "==> pnpm install --frozen-lockfile"
( cd "$FRONTEND_DIR" && pnpm install --frozen-lockfile )

# --- 手順 6: 復元されたことを script 自身が assert する ---
# 人が目視を忘れても落ちるようにする
failed=0

remaining=$(git -C "$FRONTEND_DIR" status --porcelain -- ${guarded[@]+"${guarded[@]}"})
if [[ -n "$remaining" ]]; then
  echo "NG: 保護対象に変更が残っている:" >&2
  echo "$remaining" >&2
  failed=1
fi

# clean であることは復元の証明にならない。link: 版が一度コミットされていると checkout は
# HEAD のその内容を戻すため、working tree は clean のまま link: が残る。内容そのものを見る
# （誤コミット防止 hook をすり抜けた場合の最後の検知機会）。
#
# ここは untracked も含めて全保護対象を見る。pnpm 10 以降は pnpm-workspace.yaml に
# overrides を書き、非 workspace 形状ではそれが新規ファイルなので checkout では戻らない
for one_path in ${GUARDED_PATHS[@]+"${GUARDED_PATHS[@]}"}; do
  target="$FRONTEND_DIR/$one_path"
  [[ -e "$target" ]] || continue
  # 読めないファイルを || true で飲み込むと、最後の検知機会が無音で消える。
  # grep の exit 2（不在・権限）と exit 1（一致なし）を区別する
  if [[ ! -r "$target" ]]; then
    echo "NG: 保護対象を読めないため link: の残存を確認できない: $target" >&2
    failed=1
    continue
  fi
  local_link=$(grep -nE "$LOCAL_LINK_RE" "$target" || [[ $? -eq 1 ]])
  if [[ -n "$local_link" ]]; then
    echo "NG: 復元後の $one_path に link: / file: の依存宣言が残っている:" >&2
    echo "$local_link" >&2
    if git -C "$FRONTEND_DIR" ls-files --error-unmatch -- "$one_path" >/dev/null 2>&1; then
      echo "  link: 版が commit 済みの可能性がある（checkout は HEAD の内容を戻すので clean になる）。" >&2
    else
      echo "  このファイルは git の管理下に無いため checkout では戻らない。手で戻す。" >&2
    fi
    failed=1
  fi
done

hidden=$(git -C "$FRONTEND_DIR" ls-files -v -- ${guarded[@]+"${guarded[@]}"} | grep '^S' || true)
if [[ -n "$hidden" ]]; then
  echo "NG: skip-worktree が残っている:" >&2
  echo "$hidden" >&2
  failed=1
fi

# 対象外のファイルは落とさずに知らせる（link と無関係な作業中の変更で失敗させない）。
# -F を付けるのは、パスを正規表現として扱うと package.json の . が任意 1 文字に化けて
# 無関係なパス（other/package_json.bak 等）まで一覧から消えるため
others=$(git -C "$FRONTEND_DIR" status --porcelain \
  | grep -vF -e "$CONTRACT_APP_PKG_JSON" -e "$LOCKFILE" -e "package.json" -e "pnpm-workspace.yaml" || true)
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
  echo "  破棄前の内容は退避してある: $BACKUP_DIR" >&2
  exit 1
fi

echo "unlink 完了。保護対象は clean、skip-worktree も残っていない。"
echo "  破棄した内容の退避先（不要なら削除してよい）: $BACKUP_DIR"
