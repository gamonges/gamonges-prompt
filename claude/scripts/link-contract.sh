#!/usr/bin/env bash
# contract パッケージを registry 解決からローカルパス解決へ差し替える。
# 解除は unlink-contract.sh（対で使う）。
#
# 設定はすべて環境変数で受ける（本リポジトリは PUBLIC なので、リポジトリパス・
# スコープ名・パッケージ名を script 内に直書きしない）。日常の起動が引数ゼロで済むよう、
# 既定値は ~/.zshrc の CLAUDE_CODE_CONTRACT_* から供給する:
#
#   BACKEND_DIR            ← CLAUDE_CODE_CONTRACT_BACKEND_DIR    contract を持つリポジトリ
#   FRONTEND_DIR           ← CLAUDE_CODE_CONTRACT_FRONTEND_DIR    差し替え先リポジトリ
#   CONTRACT_PKG           ← CLAUDE_CODE_CONTRACT_PKG             npm パッケージ名（build の --filter）
#   CONTRACT_PKG_DIR       ← CLAUDE_CODE_CONTRACT_PKG_DIR         BACKEND_DIR からの相対パス（link 対象）
#   CONTRACT_APP_PKG_JSON  ← CLAUDE_CODE_CONTRACT_APP_PKG_JSON    FRONTEND_DIR からの相対パス（exact pin を持つ package.json）
#   CONTRACT_REGISTRY_TOKEN_VAR ← 同名 CLAUDE_CODE_* （任意）     registry 認証に使う環境変数の名前
#
# 未設定なら usage を出して終了する（暗黙のパス解決はしない）。

set -euo pipefail

BACKEND_DIR="${BACKEND_DIR:-${CLAUDE_CODE_CONTRACT_BACKEND_DIR:-}}"
FRONTEND_DIR="${FRONTEND_DIR:-${CLAUDE_CODE_CONTRACT_FRONTEND_DIR:-}}"
CONTRACT_PKG="${CONTRACT_PKG:-${CLAUDE_CODE_CONTRACT_PKG:-}}"
CONTRACT_PKG_DIR="${CONTRACT_PKG_DIR:-${CLAUDE_CODE_CONTRACT_PKG_DIR:-}}"
CONTRACT_APP_PKG_JSON="${CONTRACT_APP_PKG_JSON:-${CLAUDE_CODE_CONTRACT_APP_PKG_JSON:-}}"
CONTRACT_REGISTRY_TOKEN_VAR="${CONTRACT_REGISTRY_TOKEN_VAR:-${CLAUDE_CODE_CONTRACT_REGISTRY_TOKEN_VAR:-}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCKFILE="pnpm-lock.yaml"

usage() {
  cat >&2 <<'USAGE'
usage: link-contract.sh

  設定は環境変数で受ける（既定値は ~/.zshrc の CLAUDE_CODE_CONTRACT_* から）:
    BACKEND_DIR             contract パッケージを持つリポジトリの絶対パス
    FRONTEND_DIR            差し替え先リポジトリの絶対パス
    CONTRACT_PKG            npm パッケージ名
    CONTRACT_PKG_DIR        BACKEND_DIR からの相対パス（link 対象のパッケージディレクトリ）
    CONTRACT_APP_PKG_JSON   FRONTEND_DIR からの相対パス（exact pin を持つ package.json）
    CONTRACT_REGISTRY_TOKEN_VAR  (任意) registry 認証に使う環境変数の名前

  一時的な上書き:
    BACKEND_DIR=/path/to/repo bash link-contract.sh
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

missing=()
[[ -n "$BACKEND_DIR" ]] || missing+=("BACKEND_DIR")
[[ -n "$FRONTEND_DIR" ]] || missing+=("FRONTEND_DIR")
[[ -n "$CONTRACT_PKG" ]] || missing+=("CONTRACT_PKG")
[[ -n "$CONTRACT_PKG_DIR" ]] || missing+=("CONTRACT_PKG_DIR")
[[ -n "$CONTRACT_APP_PKG_JSON" ]] || missing+=("CONTRACT_APP_PKG_JSON")
if (( ${#missing[@]} > 0 )); then
  echo "link-contract.sh: 未設定の環境変数: ${missing[*]}" >&2
  usage
  exit 1
fi

for dir in "$BACKEND_DIR" "$FRONTEND_DIR"; do
  [[ -d "$dir" ]] || { echo "link-contract.sh: ディレクトリが存在しない: $dir" >&2; exit 1; }
done
[[ -d "$BACKEND_DIR/$CONTRACT_PKG_DIR" ]] || {
  echo "link-contract.sh: link 対象が存在しない: $BACKEND_DIR/$CONTRACT_PKG_DIR" >&2; exit 1; }
[[ -f "$FRONTEND_DIR/$CONTRACT_APP_PKG_JSON" ]] || {
  echo "link-contract.sh: package.json が存在しない: $FRONTEND_DIR/$CONTRACT_APP_PKG_JSON" >&2; exit 1; }

# --- 事前検査 1: registry 認証 ---
# link 中も同スコープの他パッケージは registry 解決されるため、token が無いと install が落ちる
if [[ -n "$CONTRACT_REGISTRY_TOKEN_VAR" ]]; then
  if [[ -z "${!CONTRACT_REGISTRY_TOKEN_VAR:-}" ]]; then
    echo "link-contract.sh: 環境変数 $CONTRACT_REGISTRY_TOKEN_VAR が未設定。" >&2
    echo "  link 中も同スコープの他パッケージは registry 解決されるため install が失敗する。" >&2
    exit 1
  fi
else
  echo "INFO: CONTRACT_REGISTRY_TOKEN_VAR が未設定のため registry 認証の事前検査をスキップした"
fi

# --- 事前検査 2: 対象 2 ファイルが clean か ---
# dirty な状態で link すると、既存の変更を unlink の checkout が巻き込んで破棄する
dirty=$(git -C "$FRONTEND_DIR" status --porcelain -- "$CONTRACT_APP_PKG_JSON" "$LOCKFILE")
if [[ -n "$dirty" ]]; then
  echo "link-contract.sh: 対象ファイルに未コミットの変更がある。中断する:" >&2
  echo "$dirty" >&2
  echo "  unlink 時の 'git checkout' がこの変更ごと破棄するため、先に commit / stash する。" >&2
  exit 1
fi

# --- 事前検査 3: skip-worktree が既に立っていないか ---
# 立っている = 前回の link が異常終了した。unlink を促さないのは、link が中途半端な状態では
# unlink 内の pnpm 操作が失敗しうるため。まず「見えるようにする」ところまでを案内する
staged_hidden=$(git -C "$FRONTEND_DIR" ls-files -v -- "$CONTRACT_APP_PKG_JSON" "$LOCKFILE" | grep '^S' || true)
if [[ -n "$staged_hidden" ]]; then
  cat >&2 <<EOM
link-contract.sh: 対象ファイルに skip-worktree が既に立っている（前回の link が異常終了した可能性）。
  中断する。まず skip-worktree を解除して、何が残っているかを目視してから復元を判断する:

    git -C "$FRONTEND_DIR" update-index --no-skip-worktree "$CONTRACT_APP_PKG_JSON" $LOCKFILE
    git -C "$FRONTEND_DIR" status

  解除して初めて差分が見えるので、復元するか残すかを人が判断できる。
EOM
  exit 1
fi

# --- build ---
# 各リポジトリのディレクトリで pnpm を起動する（--dir で跨がない）。
# backend と frontend で pnpm のバージョンが異なる場合、--dir では cwd 側の pnpm が
# 相手のリポジトリを扱ってしまう
echo "==> build: $CONTRACT_PKG"
( cd "$BACKEND_DIR" && pnpm --filter "$CONTRACT_PKG" run build )

# --- 差し替え ---
APP_DIR="$FRONTEND_DIR/$(dirname "$CONTRACT_APP_PKG_JSON")"
echo "==> link: $APP_DIR → $BACKEND_DIR/$CONTRACT_PKG_DIR"
( cd "$APP_DIR" && pnpm link "$BACKEND_DIR/$CONTRACT_PKG_DIR" )

# --- 第一ガード: skip-worktree ---
# git がこの 2 ファイルの作業ツリー変更を一切見なくなるため、git add / commit -a / lefthook /
# IDE の commit のいずれからも、経路を問わず巻き込めない
git -C "$FRONTEND_DIR" update-index --skip-worktree "$CONTRACT_APP_PKG_JSON" "$LOCKFILE"
echo "==> skip-worktree を設定した（誤コミットの第一ガード）"

cat <<EOM

link 完了。解除するまで以下を守る:

  1. この 2 ファイルを commit しない
       $CONTRACT_APP_PKG_JSON
       $LOCKFILE
     （skip-worktree で git から隠してあるので、通常は巻き込めない）

  2. link 中に依存を追加・更新しない
     lockfile への正当な変更も skip-worktree で git status に現れず、unlink の
     'git checkout' が link 差分と一緒に破棄する。破棄に気づく手段が無い

  3. link 中の git pull を避ける
     当該ファイルへの上流変更で conflict の出方が変わる

  4. contract を変更したら build をやり直す（watch は無い）:
       cd "$BACKEND_DIR" && pnpm --filter "$CONTRACT_PKG" run build

解除:
  bash $SCRIPT_DIR/unlink-contract.sh
EOM
