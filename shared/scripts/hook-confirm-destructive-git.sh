#!/usr/bin/env bash
# PreToolUse hook: 破壊的 git 操作 (--force / --hard 等) と、既定のブランチへの push を ask 昇格する
# 公式: https://code.claude.com/docs/en/hooks
# matcher: "Bash" 限定で settings.json から登録
# permissions.ask に git push の prefix は無い（毎回の確認は中身を読まずに承認する習慣を育てるので外した）。
# push の確認は本 hook だけが出す。押す先を求められない push と、refspec の `+`（強制）は ask に倒す（素通しにするとガードが開く）。

set -euo pipefail

INPUT=$(cat)
# malformed JSON は silent miss を生むため非ゼロ終了して可観測化
# オブジェクトでない入力（配列・tool_input が false 等）も止める。jq -e . は通し、後続の jq が exit 5 で落ちて素通しする
if ! echo "$INPUT" | jq -e 'type == "object" and ((.tool_input | type) | . == "object" or . == "null")' >/dev/null 2>&1; then
  echo "$(basename "$0"): malformed input JSON" >&2
  exit 2
fi
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Codex は permissionDecision: "ask"（確認プロンプト）に未対応で、未対応の値は hook の失敗として
# 扱われ、操作が続行する（= ガードが黙って開く）。Codex の PreToolUse 入力は turn_id を持つ
# （Claude Code の入力には無い）ので、それで見分けて ask を deny に変え、確認をユーザーに戻す。
# 共通ファイルを source しない: source が失敗すると exit コードが 2 以外になり、ガードが黙って開く。
# 同じ関数を ask を返す hook に複製し、verify-skills.sh の対称性 check が存在を確かめる
decide_ask_or_deny() {  # $1=理由, $2=Codex で止めたときの次の行動（省略可）
  local decision="ask" reason="$1"
  if echo "$INPUT" | jq -e 'has("turn_id")' >/dev/null 2>&1; then
    decision="deny"
    reason="[要確認] ${reason} — Codex は確認プロンプトに未対応のため止めました。${2:-ユーザーに確認し、ユーザー自身に実行してもらってください。}"
  fi
  # trace に実際の判定を記録するため（Codex では deny）
  LAST_DECISION="$decision"
  jq -n --arg decision "$decision" --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: $decision,
      permissionDecisionReason: $reason
    }
  }'
}

if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# パターン照合はすべてここを通す（hook-block-tmp-commit.sh の matches() の複製）。echo | grep -q は、grep が
# 最初のマッチで終わると書き手が SIGPIPE で死に、pipefail で照合が偽になる（改行を含む約 64 KB 超のコマンドで
# 破壊的 git を素通しした）。grep -c は入力を読み切るので SIGPIPE が起きない
matches() {  # $1=入力, $2=拡張正規表現
  [[ "$(printf '%s\n' "$1" | grep -cE "$2" || true)" -gt 0 ]]
}

# contract-link と同じ定義。git -C <path> reset のように git とサブコマンドの間にグローバルオプションが入る形を拾うため
PATH_ARG='("[^"]*"|'"'"'[^'"'"']*'"'"'|(\\.|[^[:space:]\\])+)'
GIT_GLOBAL_OPT="(-[Cc][[:space:]]+$PATH_ARG|--[^[:space:]]+)"
GIT="git[[:space:]]+(${GIT_GLOBAL_OPT}[[:space:]]+)*"

# 破壊的 git 操作の検出パターン:
#   - git push --force / -f / --force-with-lease
#   - git reset --hard
#   - git worktree remove --force
#   - git clean -f
#   - git checkout --force
#   - git branch -D
# オプションの後ろの境界。空白・行末に加えて、シェルの区切り（; | & )）と wrapper・コマンド置換の閉じ（` " '）を
# 含める。空白と行末だけだと、`git push --force; …`・`bash -lc 'git push -f'` が素通しになる（ガードが開く）
OPT_END='([[:space:];|&)`"'"'"']|$)'
# サブコマンドの後ろの、空白で始まるオプションの直前まで。オプションの直前に空白を要求して、値の中の -f
# （ブランチ名 feat-f 等）を拾わない。短いオプションはまとめ書き（-df・-fu）も拾う
ARGS='[[:space:]](.*[[:space:]])?'
match=0
if matches "$COMMAND" "${GIT}push${ARGS}(-[a-zA-Z]*f[a-zA-Z]*|--force)${OPT_END}" \
  || matches "$COMMAND" "${GIT}"'push[[:space:]].*--force-with-lease'; then
  match=1
elif matches "$COMMAND" "${GIT}"'reset[[:space:]].*--hard'; then
  match=1
elif matches "$COMMAND" "${GIT}"'worktree[[:space:]]+remove[[:space:]].*--force'; then
  match=1
elif matches "$COMMAND" "${GIT}clean${ARGS}(-[a-zA-Z]*f[a-zA-Z]*|--force)${OPT_END}"; then
  match=1
elif matches "$COMMAND" "${GIT}checkout${ARGS}(-[a-zA-Z]*f[a-zA-Z]*|--force)${OPT_END}"; then
  match=1
elif matches "$COMMAND" "${GIT}branch${ARGS}-[a-zA-Z]*D[a-zA-Z]*${OPT_END}"; then
  match=1
fi
REASON="破壊的 git 操作を検出しました。事前にユーザー確認が必要です (CLAUDE.md の「破壊的コマンド事前確認」準拠)。"

# 強制でない push は、押す先が既定のブランチ（main・master・develop と refs/remotes/<リモート>/HEAD）のときだけ ask。
# 判定は python3 の shlex で引数を分け、押す先を refspec と git の参照（symbolic-ref・@{push}）から求める。
# git push --dry-run は pre-push フック（テスト・ネットワーク）を走らせるので使わない。
# 出力は pass か ask の理由の 1 行。python3 が落ちたときは ask に倒す（素通しにするとガードが黙って開く）。
# プログラムはコマンド置換の外で読む。bash 3.2 は $(...) の中のヒアドキュメントにあるバッククォートで
# 構文エラーになり、hook 全体が何も出さずに終わる（= 全件素通し）
read -r -d '' CLASSIFY_PUSH <<'PY' || true
import os, re, shlex, subprocess

# 値を取らない既知のオプション（git 2.50.1 の `git push -h` から写す。--no-<名前> も受ける）
FLAG_LONG = {"verbose", "quiet", "tags", "dry-run", "porcelain", "delete", "thin", "set-upstream",
             "progress", "verify", "follow-tags", "signed", "atomic", "ipv4", "ipv6",
             "force-if-includes", "force", "force-with-lease"}
FLAG_SHORT = set("vqdnuf46")
# 値を別の引数に取るオプション（= 付きはその 1 語）。値を refspec と数えない
VALUE_LONG = {"push-option", "receive-pack", "exec", "recurse-submodules"}
# 押す先を引数の外で決める・リモートを替えるもの
WIDEN = {"all", "branches", "mirror", "prune", "repo"}
# git のグローバルオプションのうち、押す先に関わらないもの。-c・--git-dir 等の残りは ask に倒す
GLOBAL_FLAGS = {"--no-pager", "-p", "--paginate", "-P", "--no-optional-locks", "--literal-pathspecs",
                "--no-replace-objects", "--glob-pathspecs", "--noglob-pathspecs", "--icase-pathspecs"}
SEPARATORS = {";", "&", "&&", "|", "||", "(", ")"}
# 後ろに別のコマンド（列）を取るもの
WRAPPERS = {"bash", "sh", "zsh", "dash", "ksh", "eval", "xargs", "sudo", "env", "command", "exec",
            "time", "nohup", "nice", "timeout", "gtimeout", "watch", "ssh", "caffeinate"}
DEFAULT_NAMES = {"main", "master", "develop"}


class Ask(Exception):
    pass


def git(d, *args):
    # 失敗は例外にせず値で返す（hook は必ず exit 0 で終える）
    try:
        r = subprocess.run(["git", "-C", d, *args], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None, ""
    return r.returncode, r.stdout.strip()


def defaults(d, remote):
    names = set(DEFAULT_NAMES)
    if d and remote:
        rc, out = git(d, "symbolic-ref", "-q", "--short", f"refs/remotes/{remote}/HEAD")
        if rc == 0 and out.startswith(remote + "/"):
            names.add(out[len(remote) + 1:])
    return names


def segments(cmd):
    # 改行もコマンドの区切り（shlex は改行を空白として読む）。行の継続は 1 行につなぐ
    cmd = cmd.replace("\\\n", " ").replace("\n", " ; ")
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    segs, cur, skip = [], [], False
    for t in lex:
        if skip:
            skip = False
        elif re.fullmatch(r"[<>&]*[<>][<>&]*", t):
            if cur and cur[-1].isdigit():
                cur.pop()
            skip = True
        elif t in SEPARATORS or set(t) <= set(";&|()"):
            segs.append(cur); cur = []
        else:
            cur.append(t)
    segs.append(cur)
    return segs


def parse_push(args):
    # 戻り値: (リモート or None, refspec の並び)
    pos, i = [], 0
    while i < len(args):
        a = args[i]
        if a == "--":
            pos.extend(args[i + 1:])
            break
        if a.startswith("--"):
            name, eq, _ = a[2:].partition("=")
            base = name[3:] if name.startswith("no-") else name
            if base in WIDEN:
                raise Ask(f"git push の --{name} は押す先を引数から決められません")
            if base in VALUE_LONG:
                if not eq and not name.startswith("no-"):
                    i += 1
            elif base not in FLAG_LONG:
                raise Ask(f"git push の知らないオプション --{name} があります")
        elif a.startswith("-") and len(a) > 1:
            for j, ch in enumerate(a[1:], start=1):
                if ch == "o":
                    if j == len(a) - 1:
                        i += 1
                    break
                if ch not in FLAG_SHORT:
                    raise Ask(f"git push の知らないオプション -{ch} があります")
        else:
            pos.append(a)
        i += 1
    return (pos[0] if pos else None), pos[1:]


def push_config(d, remote):
    # remote.<r>.push は押す先を refspec の外で決める。未設定は rc=1、それ以外は値ありか読めない
    rc, _ = git(d, "config", "--get-all", f"remote.{remote}.push")
    if rc != 1:
        raise Ask(f"remote.{remote}.push の設定が押す先を決めます")


def check_push(d, remote, refspecs, can_resolve):
    if not refspecs:
        if not can_resolve:
            raise Ask("押す先を求める git の参照が、この入力からは確かめられません（-C で repo を指すと判定できます）")
        if remote:
            push_config(d, remote)
        rc, out = git(d, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{push}")
        if rc != 0 or "/" not in out:
            raise Ask("git push の押す先（@{push}）を求められません")
        r, _, branch = out.partition("/")
        # 複数の宛先・pushRemote の食い違いを解決しようとせず、安全側に倒す
        if remote and remote != r:
            raise Ask(f"明示したリモート {remote} が @{{push}} のリモート {r} と違います")
        if not remote:
            push_config(d, r)
        if branch in defaults(d, r):
            raise Ask(f"既定のブランチ {branch} への push です")
        return
    names = defaults(d if can_resolve else "", remote)
    for spec in refspecs:
        if spec.startswith("+"):
            raise Ask(f"refspec {spec} は強制の push です")
        src, colon, dst = spec.partition(":")
        if not colon:
            dst = src
            if src in ("HEAD", "@"):
                if not can_resolve:
                    raise Ask(f"{src} の指すブランチが、この入力からは確かめられません（-C で repo を指すと判定できます）")
                rc, dst = git(d, "symbolic-ref", "-q", "--short", "HEAD")
                if rc != 0 or not dst:
                    raise Ask(f"{src} の指すブランチを求められません（detached か、repo でない）")
        if not dst or re.search(r"[~^]", dst) or (colon and dst in ("HEAD", "@")):
            raise Ask(f"refspec {spec} の押す先を決められません")
        if dst.startswith("refs/tags/"):
            continue
        if dst.startswith("refs/heads/"):
            dst = dst[len("refs/heads/"):]
        elif dst.startswith("refs/"):
            raise Ask(f"refspec {spec} の押す先 {dst} を決められません")
        if dst in names:
            raise Ask(f"既定のブランチ {dst} への push です")


def scan(cmd, cwd, codex):
    moved = False
    for seg in segments(cmd):
        k = 0
        while k < len(seg) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", seg[k]):
            k += 1
        if k >= len(seg):
            continue
        head = os.path.basename(seg[k])
        if head in ("cd", "pushd", "popd"):
            moved = True
            continue
        if head != "git":
            # bash -c "git push …"・sudo git push のように、別のコマンドから起動する push。ラッパーに限るのは、
            # gh pr create --body "… git push …" のような引数の中の文を push と取り違えないため
            if head in WRAPPERS and any(w == "push" or re.search(r"(^|[\s;&|(])git\s(.*\s)?push(\s|$)", w)
                                        for w in seg[k + 1:]):
                raise Ask(f"{head} から起動する git push は押す先を確かめられません")
            continue
        args, d, i, explicit_c = seg[k + 1:], cwd, 0, False
        while i < len(args) and args[i].startswith("-"):
            a = args[i]
            if a == "-C" and i + 1 < len(args):
                p = args[i + 1]
                d = p if os.path.isabs(p) else (os.path.join(d, p) if d else "")
                explicit_c = True
                i += 2
            elif a in GLOBAL_FLAGS:
                i += 1
            else:
                raise Ask(f"git のオプション {a} が押す先を替えうるので、確かめられません")
        if i >= len(args) or args[i] != "push":
            continue
        push_args = args[i + 1:]
        if any(re.search(r"[$`*?\[\]{}]", w) for w in push_args):
            raise Ask("git push の引数に、展開されるまで値の決まらない文字があります")
        # 前のセグメントの cd と Codex の workdir は判定のディレクトリを替えるが、hook からは見えない
        can_resolve = bool(d) and (explicit_c or not (moved or codex))
        remote, refspecs = parse_push(push_args)
        check_push(d, remote, refspecs, can_resolve)


try:
    scan(os.environ["CMD"], os.environ.get("CWD", ""), os.environ.get("IS_CODEX") == "1")
except Ask as e:
    print(e)
except ValueError as e:
    print(f"git push を含むコマンドを解析できません（{e}）")
else:
    print("pass")
PY
if [[ $match -eq 0 ]] && matches "$COMMAND" "${GIT}push(${OPT_END}|[[:space:]])"; then
  CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
  IS_CODEX=0
  if echo "$INPUT" | jq -e 'has("turn_id")' >/dev/null 2>&1; then IS_CODEX=1; fi
  if ! verdict=$(CMD="$COMMAND" CWD="$CWD" IS_CODEX="$IS_CODEX" python3 -c "$CLASSIFY_PUSH" 2>/dev/null) \
    || [[ -z "$verdict" ]]; then
    verdict="git push の判定に失敗しました"
  fi
  if [[ "$verdict" != "pass" ]]; then
    match=1
    REASON="${verdict}。既定のブランチへの push は事前にユーザー確認が必要です（既定でないブランチへの push は確認なしで通します）。"
  fi
fi

if [[ $match -eq 1 ]]; then
  decide_ask_or_deny "$REASON"
  # opt-in trace: CLAUDE_CODE_HOOK_TRACE 環境変数が定義されている時のみログ出力
  if [[ -n "${CLAUDE_CODE_HOOK_TRACE:-}" ]]; then
    mkdir -p ~/.claude/logs
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $(basename "$0") matched=true decision=${LAST_DECISION:-ask}" >> ~/.claude/logs/hook-trace.log
  fi
fi

exit 0
