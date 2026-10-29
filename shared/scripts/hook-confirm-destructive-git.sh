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
             "progress", "verify", "follow-tags", "signed", "atomic", "ipv4", "ipv6"}
FLAG_SHORT = set("vqdnu46")
# 強制の push。正規表現の側は行の継続・引用で書いた形に当たらないので、ここでも止める
FORCE_LONG = {"force", "force-with-lease", "force-if-includes"}
# 値を別の引数に取るオプション（= 付きはその 1 語）。値を refspec と数えない
VALUE_LONG = {"push-option", "receive-pack", "exec", "recurse-submodules"}
# 押す先を引数の外で決める・リモートを替えるもの
WIDEN = {"all", "branches", "mirror", "prune", "repo"}
# git のグローバルオプションのうち、押す先に関わらないもの。-c・--git-dir 等の残りは ask に倒す
GLOBAL_FLAGS = {"--no-pager", "-p", "--paginate", "-P", "--no-optional-locks", "--literal-pathspecs",
                "--no-replace-objects", "--glob-pathspecs", "--noglob-pathspecs", "--icase-pathspecs"}
SEPARATORS = {";", "&", "&&", "|", "||", "(", ")"}
# 予約語・グループの記号は前置きとして読み飛ばす。読み飛ばさないと先頭の語が if・{ になり、後ろの push を判定しない
SHELL_KEYWORDS = {"if", "then", "elif", "else", "fi", "do", "done", "while", "until", "for", "case", "esac",
                  "{", "}", "!", "time"}
# オプションを付けなければ、後ろのコマンドをそのまま起動する前置き
PREFIXES = {"nohup", "command"}
# -c の引数をシェルとして実行するもの（eval は残りの引数）。中身を同じ判定で読む
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "fish"}
# 後ろに別のコマンド（列）を取るもの。中身を読めないので、git push を含めば ask
WRAPPERS = SHELLS | {"eval", "xargs", "sudo", "env", "command", "exec", "nohup", "nice", "timeout", "gtimeout",
                     "watch", "ssh", "caffeinate", "tcsh", "csh", "script", "doas", "su", "flock", "stdbuf",
                     "unbuffer", "parallel", "busybox"}
DEFAULT_NAMES = {"main", "master", "develop"}
# 押す先を替えない GIT_* の環境変数。ほかの GIT_*（GIT_CONFIG_*・GIT_DIR 等）は、判定用の git() から
# 見えない所で押す先を替えるので、git -c・--git-dir と同じく ask
GIT_ENV_OK = re.compile(r"GIT_(TRACE\w*|SSH_COMMAND|SSH|TERMINAL_PROMPT|ASKPASS)")
GIT_PUSH_TEXT = re.compile(r"(^|[\s;&|(])git\s(.*\s)?push(\s|$)")
MAX_DEPTH = 5


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


def close_paren(s, k):
    # s[k] は "(" 。算術式の中は引用もヒアドキュメントも無いので、括弧だけを数える
    depth = 0
    for j in range(k, len(s)):
        if s[j] == "(":
            depth += 1
        elif s[j] == ")":
            depth -= 1
            if depth == 0:
                return j
    return len(s)


def walk(s, i=0, stop=False, dq=False):
    """ヒアドキュメントの本文を除き、コマンド置換の中身を取り出す。
    戻り値: (読み終えた位置, 本文を除いた文字列, 置換の中身の並び, 引用無しのヒアドキュメントの本文の並び)。
    ヒアドキュメントの本文は実行されない。先に除かないと、コミットメッセージの行を push と読む。
    コマンド置換は二重引用の中でも実行されるが、shlex では 1 つの語になるので、中身を取り出して読む。
    stop は $( の中を読むとき（対応する ) で止まる）。dq は二重引用の中として読む"""
    out, subs, bodies, pending = [], [], [], []
    n, quote, depth = len(s), ('"' if dq else None), 0
    while i < n:
        c = s[i]
        if quote == "'":
            out.append(c)
            i += 1
            if c == "'":
                quote = None
            continue
        if c == "\\" and i + 1 < n:
            out.append(s[i:i + 2])
            i += 2
            continue
        if c == "`":
            j = s.find("`", i + 1)
            end = n if j < 0 else j
            subs.append(s[i + 1:end])
            out.append(s[i:end + 1])
            i = end + 1
            continue
        if s.startswith("$((", i):
            end = close_paren(s, i + 1)
            out.append(s[i:end + 1])
            i = end + 1
            continue
        if s.startswith("$(", i):
            end, inner, _, inner_bodies = walk(s, i + 2, stop=True)
            subs.append(inner)
            bodies.extend(inner_bodies)
            out.append("$(" + inner + ")")
            i = end + 1
            continue
        if c == '"':
            if not dq:
                quote = None if quote == '"' else '"'
            out.append(c)
            i += 1
            continue
        if quote == '"':
            out.append(c)
            i += 1
            continue
        if c == "'":
            quote = "'"
            out.append(c)
            i += 1
            continue
        if s.startswith("<<", i) and not s.startswith("<<<", i):
            j = i + 2
            dash = j < n and s[j] == "-"
            if dash:
                j += 1
            while j < n and s[j] in " \t":
                j += 1
            k = j
            while k < n and not s[k].isspace() and s[k] not in ";|&<>()":
                k += 1
            word = s[j:k]
            delim = re.sub(r"[\"'\\]", "", word)
            if delim:
                pending.append((delim, word != delim, dash))
            out.append(s[i:k])
            i = k
            continue
        if c == "\n" and pending:
            out.append(c)
            i += 1
            for delim, quoted, dash in pending:
                body = []
                # 終端の行が無ければ、bash と同じく入力の終わりまでを本文にする
                while i < n:
                    e = s.find("\n", i)
                    line = s[i:] if e < 0 else s[i:e]
                    i = n if e < 0 else e + 1
                    if (line.lstrip("\t") if dash else line) == delim:
                        break
                    body.append(line)
                if not quoted:
                    bodies.append("\n".join(body))
            pending = []
            continue
        if stop and c == "(":
            depth += 1
        elif stop and c == ")":
            if depth == 0:
                return i, "".join(out), subs, bodies
            depth -= 1
        out.append(c)
        i += 1
    return n, "".join(out), subs, bodies


def segments(cmd):
    # 行の継続はシェルの意味どおり語をつなぐ（空白にすると pu\⏎sh が 2 語に分かれる）。改行もコマンドの区切り
    cmd = cmd.replace("\\\n", "").replace("\n", " ; ")
    # fd はリダイレクトの記号と隣り合うときだけ。shlex の後では隣り合っていたかが分からず、refspec の数字を捨ててしまう
    cmd = re.sub(r"(?:(?<=[\s;&|()])|^)\d+(?=[<>])", "", cmd)
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    # 語の途中の # をコメントにしない（feat#x main の main を捨てない）
    lex.commenters = ""
    segs, cur, skip = [], [], False
    for t in lex:
        if skip:
            skip = False
        elif re.fullmatch(r"[<>&]*[<>][<>&]*", t):
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
            if base in FORCE_LONG:
                if not name.startswith("no-"):
                    raise Ask(f"git push の --{name} は強制の push です")
            elif base in VALUE_LONG:
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
                if ch == "f":
                    raise Ask("git push の -f は強制の push です")
                if ch not in FLAG_SHORT:
                    raise Ask(f"git push の知らないオプション -{ch} があります")
        else:
            pos.append(a)
        i += 1
    return (pos[0] if pos else None), pos[1:]


def push_config(d, remote, strict=True):
    # remote.<r>.push は押す先を refspec の外で決める。未設定は rc=1、それ以外は値ありか読めない。
    # strict でない（cd の後・Codex で、入力の cwd で代わりに引く）ときは、値がある（rc=0）ときだけ ask を足す
    rc, _ = git(d, "config", "--get-all", f"remote.{remote}.push")
    if rc == 0 or (strict and rc != 1):
        raise Ask(f"remote.{remote}.push の設定が押す先を決めます")


def check_push(d, remote, refspecs, can_resolve, cwd):
    if not refspecs:
        if not can_resolve:
            raise Ask("押す先を求める git の参照が、この入力からは確かめられません（-C で repo を指すと判定できます）")
        # @{push} は今のブランチの押す先しか返さない。matching は同名の全ブランチ（main を含む）を押す
        rc, mode = git(d, "config", "--get", "push.default")
        if rc == 0 and mode == "matching":
            raise Ask("push.default=matching は同名の全ブランチ（既定のブランチを含む）を押します")
        if rc not in (0, 1):
            raise Ask("push.default の設定を読めません")
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
    # cd の後・Codex では判定のディレクトリが分からない。入力の cwd で設定が見つかったときだけ ask を足す
    # （ask を足す向きだけなので、cwd が別の repo でも素通しは増えない）
    probe = d if can_resolve else cwd
    names = defaults(probe, remote)
    # :<dst> を省いた refspec は、remote.<r>.push が別の ref に向けうる（git help push）
    if probe and any(":" not in spec for spec in refspecs):
        push_config(probe, remote, strict=can_resolve)
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


def assignment(t):
    m = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)=.*", t, re.S)
    return m.group(1) if m else None


def bad_git_env(name):
    return bool(name) and name.startswith("GIT_") and not GIT_ENV_OK.fullmatch(name)


def exports_git_env(seg):
    # export・declare -x・typeset -x で出した GIT_* は、同じコマンド列の後ろの git push に効く
    if not seg or seg[0] not in ("export", "declare", "typeset"):
        return False
    if seg[0] != "export" and not any(t.startswith("-") and "x" in t for t in seg[1:]):
        return False
    return any(bad_git_env(assignment(t) or t) for t in seg[1:] if not t.startswith("-"))


def shell_script(args):
    # bash -c '<script>'（-lc などのまとめ書きを含む）の <script>。-c が無ければ None
    for idx, a in enumerate(args):
        if a == "--" or not a.startswith("-"):
            return None
        if not a.startswith("--") and "c" in a[1:]:
            return args[idx + 1] if idx + 1 < len(args) else None
    return None


def plain(w):
    return w.replace("\\", "").replace('"', "").replace("'", "")


def scan(cmd, cwd, codex, depth=0, moved=False):
    if depth > MAX_DEPTH:
        raise Ask("コマンドの入れ子が深く、git push を確かめられません")
    _, stripped, subs, bodies = walk(cmd)
    for sub in subs:
        scan(sub, cwd, codex, depth + 1, moved)
    for body in bodies:
        # 引用無しのヒアドキュメントの本文は、中の置換だけが実行される
        for sub in walk(body, dq=True)[2]:
            scan(sub, cwd, codex, depth + 1, moved)
    segs = segments(stripped)
    exported = any(exports_git_env(seg) for seg in segs)
    for seg in segs:
        k, git_env = 0, False
        while k < len(seg):
            name = assignment(seg[k])
            if name:
                git_env = git_env or bad_git_env(name)
            elif not (seg[k] in SHELL_KEYWORDS
                      or (seg[k] in PREFIXES and k + 1 < len(seg) and not seg[k + 1].startswith("-"))):
                break
            k += 1
        if k >= len(seg):
            continue
        head, rest = os.path.basename(seg[k]), seg[k + 1:]
        if head in ("cd", "pushd", "popd"):
            moved = True
            continue
        if head != "git":
            # シェル系のラッパーは中身を同じ判定で読む（bash -c 'git pu\sh origin main' は内側で git push になる）
            script = shell_script(rest) if head in SHELLS else (" ".join(rest) if head == "eval" else None)
            if script is not None:
                scan(script, cwd, codex, depth + 1, moved or head != "eval")
                continue
            # ほかのラッパーの中は読めない。ラッパーに限るのは、gh pr create --body "… git push …" のような
            # 引数の中の文を push と取り違えないため
            if head in WRAPPERS:
                if any(plain(w) == "push" or GIT_PUSH_TEXT.search(plain(w)) for w in rest):
                    raise Ask(f"{head} から起動する git push は押す先を確かめられません")
                continue
            # 未知のコマンドの後ろの、別々の語の git と push（foo git push origin main）
            gi = next((j for j, w in enumerate(rest) if os.path.basename(w) == "git"), None)
            if gi is not None and "push" in rest[gi + 1:]:
                raise Ask(f"{head} の後ろの git push は押す先を確かめられません")
            continue
        args, d, i, explicit_c = rest, cwd, 0, False
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
        if i < len(args) and re.search(r"[$`]", args[i]):
            raise Ask("git のサブコマンドが、展開されるまで決まりません")
        if i >= len(args) or args[i] != "push":
            continue
        if git_env or exported:
            raise Ask("GIT_ で始まる環境変数が押す先を替えうるので、確かめられません")
        push_args = args[i + 1:]
        if any(re.search(r"[$`*?\[\]{}]", w) for w in push_args):
            raise Ask("git push の引数に、展開されるまで値の決まらない文字があります")
        # 前のセグメントの cd と Codex の workdir は判定のディレクトリを替えるが、hook からは見えない
        can_resolve = bool(d) and (explicit_c or not (moved or codex))
        remote, refspecs = parse_push(push_args)
        check_push(d, remote, refspecs, can_resolve, cwd)


try:
    scan(os.environ["CMD"], os.environ.get("CWD", ""), os.environ.get("IS_CODEX") == "1")
except Ask as e:
    print(e)
except ValueError as e:
    print(f"git push を含むコマンドを解析できません（{e}）")
else:
    print("pass")
PY
# 前段は緩く取り、判定は python に任せる。前段を正規表現で絞ると、引用・エスケープ・行の継続・-C. の形が
# python に届かず素通しになる。引用符・バックスラッシュ・改行を除いてから探す（pu\sh・p"u"sh・pu\⏎sh を拾う）。
# python を起動するかだけを決めるので、緩くしても ask は増えない。除くのは tr で行う（bash 3.2 の ${var//…/} は
# 約 64 KB のコマンドで数分かかり、hook が時間切れになる）。tr が失敗したら python に回す（素通しにしない）
PUSH_PROBE=$(printf '%s' "$COMMAND" | tr -d '\n"\\'"'") || PUSH_PROBE=push
if [[ $match -eq 0 && "$PUSH_PROBE" == *push* ]]; then
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
