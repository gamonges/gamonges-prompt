#!/usr/bin/env bash
# PreToolUse hook: dresscode 系リポジトリでの vitest の全件実行（test / sql-test）を block する
# 公式: https://code.claude.com/docs/en/hooks
# matcher: "Bash" 限定で settings.json から登録
#
# 背景: dresscode-backend の `pnpm run test`（全件）や `pnpm sql-test` は 1 本でも数 GB・数コアを使い、
#   複数の worktree のセッションが同時に走らせると PC が固まる。typecheck は scripts/heavy-task-lock.sh で
#   マシン全体 1 本に絞られているが、test と sql-test には枠が無い。
#   hook-block-full-lint.sh と同じく deny-by-default で判定する:
#   「対象を絞った痕跡（位置引数のパス・--changed 等）が無ければ全件とみなして block」。
#
# 対象とする呼び出し（セグメントごと。&& ; | || で区切る）:
#   - pnpm/npm/yarn [run] test | sql-test | test:ci | test:cov | test:watch
#   - [pnpm exec | npx | pnpm | yarn] vitest [run|watch]（node_modules/.bin/vitest 等のパス指定も含む）
# 絞った痕跡とみなすもの:
#   - 位置引数（ファイル・ディレクトリ・名前のフィルタ）。値を取るオプションの値は数えない
#   - --changed / --related
# 抜け道: セグメントの先頭に ALLOW_FULL_TEST=1 を付ける（オーナーが全件を明示的に許したときだけ使う）
# 適用範囲: cwd かコマンドに "dresscode" を含むときだけ（他のリポジトリの小さなテストは止めない）
# 既知の制限: 引用符の中の空白で語を割るので、-t "複数語の名前" の 2 語目以降を位置引数と数えて通す

set -euo pipefail

INPUT=$(cat)
# オブジェクトでない入力（配列・tool_input が false 等）も止める。jq -e . は通し、後続の jq が exit 5 で落ちて素通しする
if ! echo "$INPUT" | jq -e 'type == "object" and ((.tool_input | type) | . == "object" or . == "null")' >/dev/null 2>&1; then
  echo "$(basename "$0"): malformed input JSON" >&2
  exit 2
fi
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

if [[ -z "$COMMAND" ]]; then
  exit 0
fi

if [[ "$CWD" != *dresscode* && "$COMMAND" != *dresscode* ]]; then
  exit 0
fi

# 値を取る vitest / pnpm のオプション。次の語を位置引数として数えない
VALUE_FLAGS=" --config -c --project --maxWorkers --minWorkers --pool --reporter --root -r --dir -C --testNamePattern -t --shard --exclude --environment --outputFile --mode --filter --workspace "

# $@ = 1 セグメントの語。全件実行なら 0、それ以外は 1 を返す
is_full_test() {
  local -a t=("$@")
  local n=${#t[@]} i=0 kind=""

  # 先頭の環境変数代入・ラッパーを外す
  while (( i < n )); do
    case "${t[i]}" in
      ALLOW_FULL_TEST=1) return 1 ;;
      *=*) i=$((i + 1)) ;;
      env | time | command | nice | node) i=$((i + 1)) ;;
      timeout) ((i += 2)) ;;
      bash | sh | zsh) i=$((i + 1)); [[ "${t[i]:-}" == -*c* ]] && i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  (( i < n )) || return 1

  local head="${t[i]}"
  case "$head" in
    pnpm | npm | yarn)
      i=$((i + 1))
      while (( i < n )) && [[ "${t[i]}" == -* ]]; do
        [[ "$VALUE_FLAGS" == *" ${t[i]} "* ]] && i=$((i + 1))
        i=$((i + 1))
      done
      [[ "${t[i]:-}" == run ]] && i=$((i + 1))
      if [[ "${t[i]:-}" == exec || "${t[i]:-}" == dlx ]]; then
        i=$((i + 1))
        head="${t[i]:-}"
      else
        case "${t[i]:-}" in
          test | sql-test | test:ci | test:cov | test:watch) kind=script; i=$((i + 1)) ;;
          vitest) head=vitest ;;
          *) return 1 ;;
        esac
      fi
      ;;
    npx) i=$((i + 1)); head="${t[i]:-}" ;;
  esac

  if [[ -z "$kind" ]]; then
    case "$head" in
      vitest | */vitest | */vitest.mjs) kind=vitest; i=$((i + 1)) ;;
      *) return 1 ;;
    esac
    case "${t[i]:-}" in run | watch | dev) i=$((i + 1)) ;; esac
  fi

  # 残りの語に絞った痕跡があるか
  while (( i < n )); do
    local w="${t[i]}"
    case "$w" in
      --) ;;
      --changed* | --related*) return 1 ;;
      [0-9]*\>* | \>* | \<* | \&\>* | \&)
        # リダイレクト。> file のように対象が別の語なら、それも飛ばす
        [[ "$w" =~ ^[0-9\&]*[\<\>]+$ ]] && i=$((i + 1))
        ;;
      -*)
        if [[ "$w" != *=* && "$VALUE_FLAGS" == *" $w "* ]]; then
          i=$((i + 1))
        elif [[ "${t[i + 1]:-}" == true || "${t[i + 1]:-}" == false ]]; then
          i=$((i + 1))  # --coverage.enabled false のような真偽値
        fi
        ;;
      *) return 1 ;;  # 位置引数 = 対象を絞っている
    esac
    i=$((i + 1))
  done
  return 0
}

matched=0
# 区切り（&& || ; | 改行）でセグメントに分け、引用符と括弧は外して語に分ける
while IFS= read -r seg; do
  seg="${seg//[\"\'()]/ }"
  read -r -a words <<<"$seg" || true
  (( ${#words[@]} > 0 )) || continue
  if is_full_test "${words[@]}"; then
    matched=1
    break
  fi
done < <(printf '%s\n' "$COMMAND" | sed -E 's/(\|\||&&|;|\|)/\n/g')

if [[ $matched -eq 0 ]]; then
  exit 0
fi

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "vitest の全件実行（pnpm test / pnpm sql-test / 引数なしの vitest）を検出しました。全件は 1 本でも重く、複数の worktree のセッションが同時に走らせると PC が固まります。変更に関係するファイルかディレクトリを指定して実行してください（例: pnpm exec vitest run src/<対象>、pnpm sql-test src/<対象>）。全件がどうしても必要なら、ユーザーに確認したうえで先頭に ALLOW_FULL_TEST=1 を付けてください。"
  }
}
EOF

if [[ -n "${CLAUDE_CODE_HOOK_TRACE:-}" ]]; then
  mkdir -p ~/.claude/logs
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $(basename "$0") matched=true decision=deny" >> ~/.claude/logs/hook-trace.log
fi

exit 0
