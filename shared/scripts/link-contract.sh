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
#
# ---------------------------------------------------------------------------
# サポートする pnpm のバージョン
# ---------------------------------------------------------------------------
# 実測は pnpm 11.15.1。この版の `pnpm link <path>` は
#   - CONTRACT_APP_PKG_JSON（apps/<app>/package.json）を書き換えない
#   - FRONTEND_DIR 直下の package.json に dependencies: { <pkg>: link:... } を書く
#   - pnpm-workspace.yaml に overrides: を書く（非 workspace 形状では新規作成する）
# pnpm ≤9 は app 側の package.json を書き換えると見られるが未検証。
#
# バージョン差を静かに素通しさせないため、保護対象は「想定しうるものすべて」を挙げ、
# pnpm link 後に**実際に変わったか**を検査する（手順 6）。想定と食い違えばそこで止まる。

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

# 保護対象。pnpm のバージョンで書き換わるファイルが変わるため、想定しうるものをすべて挙げる。
# FRONTEND_DIR 直下の固定相対パスとして扱うのは LOCKFILE と同じ扱いで、新しい環境変数を
# 増やさないため（FRONTEND_DIR がリポジトリルート兼 workspace root であることは、
# CONTRACT_APP_PKG_JSON が FRONTEND_DIR からの相対パスである時点で既存スクリプトの前提）
GUARDED_PATHS=("$CONTRACT_APP_PKG_JSON" "$LOCKFILE" "package.json" "pnpm-workspace.yaml")

# CONTRACT_APP_PKG_JSON がルート直下の package.json を指す構成では重複するので畳む。
# mapfile / readarray は使わない（bash 4.0+ の組み込みで、macOS 標準の bash 3.2 には無い。
# しかも未定義コマンドは set -e でも配列を空のまま素通しさせるため、fail-open になる）
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

# index に登録されている保護対象だけを返す。git は未登録パスへ skip-worktree を張れない
tracked_guarded_paths() {
  local p
  for p in ${GUARDED_PATHS[@]+"${GUARDED_PATHS[@]}"}; do
    if git -C "$FRONTEND_DIR" ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
      printf '%s\n' "$p"
    fi
  done
}

# 第一ガードを張った対象（= tracked な保護対象）の内容のハッシュ。
# pnpm link が実際に何を書き換えたかを知るために使う。
#
# git status / git diff では観測できない — skip-worktree を張った対象は git が作業ツリーの
# 変更を一切見なくなるため（それが第一ガードの効能そのもの）。中身を直接ハッシュすれば
# skip-worktree の影響を受けない。
#
# untracked な保護対象を混ぜてはいけない。混ぜると、pnpm が新規作成した
# pnpm-workspace.yaml が「(missing) → ハッシュ」の変化として現れ、
# 「tracked を 1 つも守れていない」状況を「tracked が変わった」と誤判定する
hash_guarded_tracked() {
  local p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if [[ -f "$FRONTEND_DIR/$p" ]]; then
      printf '%s %s\n' "$p" "$(git -C "$FRONTEND_DIR" hash-object -- "$p")"
    else
      printf '%s (missing)\n' "$p"
    fi
  done < <(tracked_guarded_paths)
}

# 追加行に link: / file: のローカル依存宣言が含まれるか。package.json と lockfile で
# 表現が異なるため（"name": "link:..." と specifier: link:...）両方を見る
LOCAL_LINK_RE='^\+[^+].*("[^"]+"[[:space:]]*:[[:space:]]*"(link:|file:)|specifier:[[:space:]]*['"'"'"]?(link:|file:))'

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

# --- 事前検査 2: 保護対象が clean か ---
# dirty な状態で link すると、既存の変更を unlink の checkout が巻き込んで破棄する。
# 案内は dirty の**中身**で分岐する。前回の link 残骸（link: / file: を含む）に対して
# 「先に commit / stash する」と言うと、ガードレール自身が防ごうとしている事故を指示することになる
dirty=$(git -C "$FRONTEND_DIR" status --porcelain -- ${GUARDED_PATHS[@]+"${GUARDED_PATHS[@]}"})
if [[ -n "$dirty" ]]; then
  echo "link-contract.sh: 保護対象に未コミットの変更がある。中断する:" >&2
  echo "$dirty" >&2
  # grep -q へパイプしない。読み手が早期終了すると書き手が SIGPIPE で死んで
  # pipefail がパイプライン全体を 141 にし、判定が黙って反転する（hook 側で 5 箇所直したのと
  # 同じ機序）。ここは入力が小さく実害は無いが、原則の例外を repo に残さない
  if [[ "$(git -C "$FRONTEND_DIR" diff -- ${GUARDED_PATHS[@]+"${GUARDED_PATHS[@]}"} \
           | grep -cE "$LOCAL_LINK_RE" || true)" != "0" ]]; then
    echo "  この変更は前回の link の残骸（link: / file: を含む）。commit / stash してはいけない。" >&2
    echo "  先に復元する:  bash $SCRIPT_DIR/unlink-contract.sh" >&2
  else
    echo "  unlink 時の 'git checkout' がこの変更ごと破棄するため、先に commit / stash する。" >&2
  fi
  exit 1
fi

# --- 事前検査 3: skip-worktree が既に立っていないか ---
# 立っている = 前回の link が異常終了した。unlink を促さないのは、link が中途半端な状態では
# unlink 内の pnpm 操作が失敗しうるため。まず「見えるようにする」ところまでを案内する
staged_hidden=$(git -C "$FRONTEND_DIR" ls-files -v -- ${GUARDED_PATHS[@]+"${GUARDED_PATHS[@]}"} | grep '^S' || true)
if [[ -n "$staged_hidden" ]]; then
  cat >&2 <<EOM
link-contract.sh: 保護対象に skip-worktree が既に立っている（前回の link が異常終了した可能性）。
  中断する。まず skip-worktree を解除して、何が残っているかを目視してから復元を判断する:

    git -C "$FRONTEND_DIR" update-index --no-skip-worktree ${GUARDED_PATHS[*]}
    git -C "$FRONTEND_DIR" status

  解除して初めて差分が見えるので、復元するか残すかを人が判断できる。
EOM
  exit 1
fi

# --- 事前検査 4: 保護対象が index に登録されているか ---
# ls-files -v は未登録パスに対して exit 0 かつ空出力を返すため、事前検査 3 では素通しする。
# 検査しないと pnpm link（手順 5）の後に update-index が fatal で落ち、manifest だけ
# 書き換わった復旧不能な状態が残る。unlink-contract.sh の存在チェックと対称にする
if [[ -z "$(tracked_guarded_paths)" ]]; then
  echo "link-contract.sh: 保護対象が 1 つも git の管理下に無い: ${GUARDED_PATHS[*]}" >&2
  echo "  CONTRACT_APP_PKG_JSON / FRONTEND_DIR の設定を確認する（FRONTEND_DIR からの相対パスで指定する）。" >&2
  exit 1
fi

# --- build ---
# 各リポジトリのディレクトリで pnpm を起動する（--dir で跨がない）。
# backend と frontend で pnpm のバージョンが異なる場合、--dir では cwd 側の pnpm が
# 相手のリポジトリを扱ってしまう
echo "==> build: $CONTRACT_PKG"
( cd "$BACKEND_DIR" && pnpm --filter "$CONTRACT_PKG" run build )

# --- 第一ガード（pnpm link より前に張る）---
# update-index --skip-worktree はファイルの内容を変えないので、ここで失敗しても残骸が出ない。
# 逆に pnpm link を先に走らせると、index.lock の競合や未登録パスで update-index が落ちたとき、
# manifest だけ書き換わった状態が残り、しかも link-contract.sh も unlink-contract.sh も
# その状態から復旧できない（両者の事前検査に引っかかる）
guard_now=()
while IFS= read -r one_path; do
  [[ -n "$one_path" ]] && guard_now+=("$one_path")
done < <(tracked_guarded_paths)
if ! git -C "$FRONTEND_DIR" update-index --skip-worktree -- ${guard_now[@]+"${guard_now[@]}"}; then
  echo "link-contract.sh: skip-worktree を設定できなかった。まだ何も書き換えていないので、そのまま中断する。" >&2
  echo "  別の git 操作が index.lock を保持している可能性がある（IDE / 別セッションの commit）。" >&2
  exit 1
fi
echo "==> skip-worktree を設定した（誤コミットの第一ガード）: ${guard_now[*]}"

if (( ${#guard_now[@]} == 0 )); then
  echo "WARN: 第一ガードを張れなかった（保護対象が 1 つも git の管理下に無い）。" >&2
  echo "  この構成では 2 枚目のガード（hook）のみが防御になる。hook は Claude Code の" >&2
  echo "  Bash 経路しか通らないため、人の端末 / IDE / lefthook からの commit は素通しする。" >&2
fi

# 差し替え前の内容を記録する（手順 6 の比較用）
before_hash=$(hash_guarded_tracked)
before_untracked=$(git -C "$FRONTEND_DIR" status --porcelain --untracked-files=all | grep '^??' || true)

# --- 差し替え ---
APP_DIR="$FRONTEND_DIR/$(dirname "$CONTRACT_APP_PKG_JSON")"
echo "==> link: $APP_DIR → $BACKEND_DIR/$CONTRACT_PKG_DIR"
if ! ( cd "$APP_DIR" && pnpm link "$BACKEND_DIR/$CONTRACT_PKG_DIR" ); then
  echo "link-contract.sh: pnpm link が失敗した。復元する:  bash $SCRIPT_DIR/unlink-contract.sh" >&2
  exit 1
fi

# --- 手順 6: pnpm が実際に何を書き換えたかを検査する ---
# 保護対象を固定する方式なので、pnpm のバージョン差はここで顕在化させる。想定と食い違ったら
# 静かに素通しせず止まる（あるいは何が守れていないかを出力する）。
#
# 3 分岐にするのは「何も変わらない」（pnpm link が機能していない = 異常）と
# 「変わったが全て untracked」（非 workspace 形状の正規挙動）を区別する必要があるため
after_hash=$(hash_guarded_tracked)
after_untracked=$(git -C "$FRONTEND_DIR" status --porcelain --untracked-files=all | grep '^??' || true)

new_untracked=$(comm -13 <(printf '%s\n' "$before_untracked" | sort) \
                         <(printf '%s\n' "$after_untracked" | sort) | sed 's/^?? //' | grep -v '^$' || true)

if [[ "$before_hash" == "$after_hash" && -z "$new_untracked" ]]; then
  echo "link-contract.sh: pnpm link が保護対象を 1 つも変更しなかった。想定外なので中断する。" >&2
  echo "  この pnpm のバージョンが別のファイルを書き換えている可能性がある。" >&2
  echo "  第一ガード（skip-worktree）は張ったままなので、解除してから状態を確認する:" >&2
  echo "    git -C \"$FRONTEND_DIR\" update-index --no-skip-worktree ${guard_now[*]}" >&2
  echo "    git -C \"$FRONTEND_DIR\" status --untracked-files=all" >&2
  exit 1
fi

if [[ "$before_hash" == "$after_hash" ]]; then
  # tracked な保護対象は 1 つも変わらず、新規の untracked ファイルだけが増えた形。
  # 実 pnpm 11 の非 workspace 形状（pnpm-workspace.yaml を新規作成する）がこれに該当する
  echo "WARN: 第一ガードを張れなかった — pnpm が書き換えたのは git の管理下に無いファイルだけだった:" >&2
  printf '    %s\n' "$new_untracked" >&2
  echo "  skip-worktree は git の管理下にあるファイルにしか張れないため、この構成では" >&2
  echo "  2 枚目のガード（hook）のみが防御になる。hook は Claude Code の Bash 経路しか" >&2
  echo "  通らないので、人の端末 / IDE / lefthook からの commit は素通しする。" >&2
elif [[ -n "$new_untracked" ]]; then
  # tracked も変わったが、加えて管理外のファイルも増えている
  echo "WARN: 第一ガードの外に置かれたファイルがある（git の管理下に無いため skip-worktree の対象外）:" >&2
  printf '    %s\n' "$new_untracked" >&2
  echo "  これらは commit しないこと（hook が pnpm-workspace.yaml も検査する）。" >&2
fi

cat <<EOM

link 完了。解除するまで以下を守る:

  1. 保護対象を commit しない
$(printf '       %s\n' ${GUARDED_PATHS[@]+"${GUARDED_PATHS[@]}"})
     （git の管理下にあるものは skip-worktree で隠してあるので、通常は巻き込めない）

  2. link 中に依存を追加・更新しない
     lockfile への正当な変更も skip-worktree で git status に現れず、unlink の
     'git checkout' が link 差分と一緒に破棄する。破棄に気づく手段が無い

  3. link 中はブランチ切替・merge・pull ができない
     skip-worktree を張ったファイルに上流変更が来ると git は "Entry not uptodate" で
     止まり、checkout -f でも進めない。git status は clean、stash は「保存するものが無い」、
     checkout は「commit か stash しろ」と存在しない選択肢を案内するため、
     エラーメッセージから脱出方法は分からない。先に unlink すること

  4. contract を変更したら build をやり直す（watch は無い）:
       cd "$BACKEND_DIR" && pnpm --filter "$CONTRACT_PKG" run build

解除:
  bash $SCRIPT_DIR/unlink-contract.sh
EOM
