#!/usr/bin/env bash
# PreToolUse hook: 依存宣言が link: / file: のままの package.json を commit しようとしたら ask
# 公式: https://code.claude.com/docs/en/hooks
# matcher: "Bash" 限定で settings.json から登録
#
# 位置づけ: link-contract.sh が張る git update-index --skip-worktree が第一ガードで、
# 本 hook は 2 枚目（それを張り忘れた場合と、他経路で link: / file: が混入した場合）。
# hook は Claude Code の Bash 経路しか守れず、手動 commit / IDE / lefthook / wrapper 経由の
# commit を素通しするため、単独では「最後の防波堤」を名乗れない。
#
# パッケージ名もリポジトリパスも持たない汎用パターンで判定する:
#   - settings.json は PUBLIC リポジトリにコミットされるため、引数にパスを書けない
#   - Claude Code は settings.json env の ${VAR} 展開を非サポートで、hook プロセスが
#     ~/.zshrc を source する保証も無いため、環境変数でも渡せない
#   - pnpm workspace は workspace: プロトコルを使うので、コミットされた package.json の
#     link: / file: はほぼ常に事故。汎用にすると適用範囲も広がる
#
# 判定は deny ではなく ask。file: を正規に使うリポジトリでの誤爆に備える
# （bypassPermissions 下では deny にマッチした操作は確認プロンプトなしでブロックされる）。

set -euo pipefail

INPUT=$(cat)
# malformed JSON は silent miss を生むため非ゼロ終了して可観測化
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then
  echo "$(basename "$0"): malformed input JSON" >&2
  exit 2
fi
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

trace() {
  if [[ -n "${CLAUDE_CODE_HOOK_TRACE:-}" ]]; then
    mkdir -p ~/.claude/logs
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $(basename "$0") $*" >> ~/.claude/logs/hook-trace.log
  fi
}

ask() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $reason
    }
  }'
}

if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# パス引数のパターン。引用符付きの候補を先に並べるのは、スペースを含むパスを途中で切らないため。
# 切ると (a) git commit の判定でオプションを読み飛ばせず `commit` に到達できない、
# (b) 基点が誤ったパスになり手順 4 の足切りで素通しする（どちらも fail-open）
PATH_ARG='("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+)'
GIT_GLOBAL_OPT="(-[Cc][[:space:]]+$PATH_ARG|--[^[:space:]]+)"

# 1. git commit か判定する（コマンド境界を考慮。git の後に来られるのはグローバルオプションのみに絞り、
#    `git add foo commit` のような偽陽性を避ける）。境界にはサブシェルの開き括弧と
#    コマンド置換のバッククォートも含める。含めないと `echo $(git commit)` が素通しする
GIT_COMMIT_RE="(^|[;&|(\`])[[:space:]]*git[[:space:]]+(${GIT_GLOBAL_OPT}[[:space:]]+)*commit([[:space:]]|\$)"
if ! echo "$COMMAND" | grep -qE "$GIT_COMMIT_RE"; then
  exit 0
fi

# 2-3. 基点を決める。既定は .cwd で、コマンドから静的に抽出できれば上書きする。
#      $ やバッククォートを含むパスは展開できないので「確定できていない」として扱う
base="$CWD"
base_resolved=1

extract_path() {
  local raw="$1"
  # 引用符を外す（'path' / "path" の両方）
  raw="${raw%\"}"; raw="${raw#\"}"
  raw="${raw%\'}"; raw="${raw#\'}"
  if [[ "$raw" == *'$'* || "$raw" == *'`'* || -z "$raw" ]]; then
    echo ""
    return
  fi
  # ~ は hook プロセスと同じ HOME で展開して差し支えない
  raw="${raw/#\~/$HOME}"
  echo "$raw"
}

resolve_base() {
  local candidate="$1"
  if [[ "$candidate" == /* ]]; then
    echo "$candidate"
  elif [[ -n "$CWD" ]]; then
    echo "$CWD/$candidate"
  else
    echo ""
  fi
}

count_matches() {
  if [[ -z "$1" ]]; then
    echo 0
  else
    printf '%s\n' "$1" | wc -l | tr -d ' '
  fi
}

# 先頭に付く区切り文字（; & | と、サブシェルの開き括弧）と空白を落としてから cd を落とす。
# 1 回の貪欲マッチ（s/^.*cd[[:space:]]+//）で済ませるとパス中の "cd " で切れる
# （例: /path/abcd efg → efg）。アンカーを効かせ、剥がす対象を 2 段に分けて明示する
strip_cd_prefix() {
  printf '%s\n' "$1" | sed -E 's/^[;&|(]?[[:space:]]*cd[[:space:]]+//'
}

# 解決した基点を採用してよいか。実在するディレクトリであることを条件にするのは、
# 静的に解決できない形（cd - のような直前ディレクトリ参照、タイプミス、取り逃した展開）を
# まとめて「確定できなかった」に落とすため。存在しないパスを基点にすると、足切りが
# そこに pnpm-lock.yaml を見つけられず「pnpm 非使用」と誤判定して素通しする
usable_base() {
  [[ -n "$1" && -d "$1" ]]
}

# サブシェル形 ( cd repo && git commit ) は本 repo の script 自身が使う記法なので、
# 先頭の許容文字に開き括弧を含める
CD_RE="(^|[;&|(])[[:space:]]*cd[[:space:]]+$PATH_ARG"
GIT_C_RE="git[[:space:]]+-C[[:space:]]+$PATH_ARG"

# 基点候補の抽出元は cd と git -C で分ける。cd は git commit の前に置かれる別コマンドなので
# 位置関係が意味を持ち、-C は git commit 呼び出しそのものの引数なので呼び出しの内側にある。
# 対称に扱って両方をコマンド全体から取ると、git commit より後ろの cd が基点を上書きする。
# 逆に両方を手前 (prefix) から取ると、git -C <path> commit の -C はマッチの内側にあるため
# 基点解決が働かなくなる。どちらも足切りを「pnpm 非使用」に倒して素通しさせる
#
# この正規表現を bash の [[ =~ ]] で照合してはならない。grep は行単位、bash は文字列全体で
# ^ を解釈するため、改行区切りの git commit が bash 側で一致せず hook が丸ごとスキップされる。
# 境界クラスに改行を足す回避も、改行入りパターンを grep が複数パターンとして解釈するので採れない
matched=$(echo "$COMMAND" | grep -oE "$GIT_COMMIT_RE" || true)
# 先頭の一致だけを使う。head -1 を挟むと SIGPIPE で grep が死に、pipefail + set -e で
# スクリプトごと落ちる。hook が無出力で終わると non-blocking 扱いになりガードが黙って開く
matched="${matched%%$'\n'*}"
# リテラルの最初の出現で切るため、同じ文字列が手前にあると prefix が短くなる。
# その場合の結果は「基点を上書きしない」= 安全側
prefix="${COMMAND%%"$matched"*}"

GIT_C_MATCHES=$(echo "$matched" | grep -oE "$GIT_C_RE" || true)
CD_MATCHES=$(echo "$prefix" | grep -oE "$CD_RE" || true)

# 基点の候補を 1 つに絞れないときは base を上書きしない（.cwd のまま残す）。
# 誤った値で上書きすると、手順 4 の足切りがその誤った base を見て「pnpm 非使用」と判定し、
# 手順 5 の fail-closed に到達する前に exit 0 する。フラグを立てるだけでは安全側に倒れない
if [[ -n "$GIT_C_MATCHES" ]]; then
  if [[ "$(count_matches "$GIT_C_MATCHES")" -gt 1 ]]; then
    base_resolved=0
  else
    extracted=$(extract_path "$(echo "$GIT_C_MATCHES" | sed -E 's/^git[[:space:]]+-C[[:space:]]+//')")
    resolved=$(resolve_base "$extracted")
    if [[ -n "$extracted" ]] && usable_base "$resolved"; then
      base="$resolved"
    else
      base_resolved=0
    fi
  fi
elif [[ -n "$CD_MATCHES" ]]; then
  if [[ "$(count_matches "$CD_MATCHES")" -gt 1 ]]; then
    base_resolved=0
  else
    extracted=$(extract_path "$(strip_cd_prefix "$CD_MATCHES")")
    resolved=$(resolve_base "$extracted")
    if [[ -n "$extracted" ]] && usable_base "$resolved"; then
      base="$resolved"
    else
      base_resolved=0
    fi
  fi
fi

# 基点をリポジトリルートへ解決する。守る対象は apps/<app>/package.json であり、その app
# ディレクトリで作業して commit するのは例外ではなく主経路。サブディレクトリを起点に
# pnpm-lock.yaml を探すと「pnpm 非使用」と誤判定してガードが全面素通しする。
# 解決できない場合（git 管理外）は素通しでよい。ここを ask にすると非 git ディレクトリでの
# commit 全般が ask になり、手順 4 が避けている ask 疲れを招く
if [[ -n "$base" ]] && toplevel=$(git -C "$base" rev-parse --show-toplevel 2>/dev/null); then
  base="$toplevel"
fi

# 4. 足切り: pnpm を使わないリポジトリは対象外。
#    fail-closed（手順 5）より前に置く。逆順にすると、変数展開を含む commit が pnpm 非使用の
#    リポジトリでも ask になり、日常的に出るプロンプトが「中身を読まずに承認する習慣」を育てる。
#    それは fail-open とは別方向で、同じくガードを無効化する。
#    基点が確定していない場合は .cwd を足切りの材料に使う（cd 先が pnpm リポジトリかは分からないが、
#    コマンドを打った場所が pnpm と無縁なら、その commit も無縁である可能性が高い）
if [[ -z "$base" || ! -f "$base/pnpm-lock.yaml" ]]; then
  trace "matched=false reason=not-pnpm-repo base=${base:-none}"
  exit 0
fi

# 5. 基点を確定できていなければ ask（fail-closed）。
#    ここまで来た時点で pnpm を使うリポジトリなので、ask に価値がある
if [[ "$base_resolved" -eq 0 ]]; then
  ask "git commit の対象リポジトリを静的に特定できませんでした（変数展開を含むパス / 複数の cd / 実在しないパス など）。pnpm を使うリポジトリなので、依存宣言が link: / file: のままの package.json を巻き込んでいないか確認のうえ承認してください。"
  trace "matched=true decision=ask reason=base-unresolved"
  exit 0
fi

# 6. commit の対象範囲を決める。
#    commit -a / -am / --all は staged していない変更も取り込むため、--cached だけを見ると
#    素通しする。link-contract.sh は skip-worktree の効能として commit -a を挙げており、
#    本 hook はそれを張り忘れた場合の 2 枚目なので、この経路を見ないと 2 枚目の意味が薄れる。
#    --amend は -a ではないので拾わない（2 文字目の - は [A-Za-z] に該当せず短縮形にマッチしない）
COMMIT_ARGS=${COMMAND#*commit}
if echo "$COMMIT_ARGS" | grep -qE '(^|[[:space:]])(--all([[:space:]]|=|$)|-[A-Za-z]*a[A-Za-z]*([[:space:]]|$))'; then
  DIFF_SCOPE=(diff HEAD)
  scope_label=diff-head
else
  DIFF_SCOPE=(diff --cached)
  scope_label=diff-cached
fi

# 7. 対象に package.json / pnpm-lock.yaml が含まれるか
if ! changed=$(git -C "$base" "${DIFF_SCOPE[@]}" --name-only 2>/dev/null); then
  trace "matched=false reason=git-failed base=$base scope=$scope_label"
  exit 0
fi
if ! echo "$changed" | grep -qE '(^|/)(package\.json|pnpm-lock\.yaml)$'; then
  trace "matched=false reason=no-manifest-changed base=$base scope=$scope_label"
  exit 0
fi

# 8. 追加行に link: / file: の依存宣言があるか。既存行は事故ではないので追加行（^+）だけを見る。
#    package.json と lockfile は表現が異なるため（"name": "link:..." と specifier: link:...）
#    同じパターンを使い回すと lockfile 側が一致せず静かに素通しする。
#    lockfile 側で見るのは specifier:（宣言）だけで version:（解決結果）は見ない。
#    workspace 依存は version: link:../pkg という正しい姿を取るため、version: を見ると
#    正常な commit で日常的に ask が出る。読まずに承認する習慣は fail-open と同じくガードを殺す
if git -C "$base" "${DIFF_SCOPE[@]}" -- '*package.json' 2>/dev/null \
   | grep -qE '^\+[^+].*"[^"]+"[[:space:]]*:[[:space:]]*"(link:|file:)'; then
  ask "commit 対象の package.json に link: / file: のローカル依存宣言が含まれています。ローカル結合のまま commit すると CI の --frozen-lockfile が壊れます。unlink-contract.sh で復元してから commit するか、正規の file: 依存であることを確認のうえ承認してください。"
  trace "matched=true decision=ask reason=local-link-package-json base=$base scope=$scope_label"
  exit 0
fi

if git -C "$base" "${DIFF_SCOPE[@]}" -- '*pnpm-lock.yaml' 2>/dev/null \
   | grep -qE '^\+[^+].*specifier:[[:space:]]*['"'"'"]?(link:|file:)'; then
  ask "commit 対象の pnpm-lock.yaml に link: / file: のローカル解決が含まれています。ローカル結合のまま commit すると CI の --frozen-lockfile が壊れます。unlink-contract.sh で復元してから commit するか、正規の file: 依存であることを確認のうえ承認してください。"
  trace "matched=true decision=ask reason=local-link-lockfile base=$base scope=$scope_label"
  exit 0
fi

trace "matched=false reason=no-local-link base=$base"
exit 0
