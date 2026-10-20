#!/usr/bin/env bash
# PreToolUse hook: localhost 以外へ向かう curl を ask 昇格する
# 公式: https://code.claude.com/docs/en/hooks
# matcher: "Bash" 限定で settings.json から登録
# permissions.ask の Bash(curl:*) は「localhost なら許可」を表せない（ルールに否定が無く、ask は allow より先に
# 評価される）ので、ask から外して本 hook で宛先を見る。宛先がすべてローカルなら何も出さず素通しにする。

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

# curl の語を含まないコマンドは解析しない（日常の大半をここで返す）
if [[ "$COMMAND" != *curl* ]]; then
  exit 0
fi

# 判定は python3 の shlex で行う（引用・オプションの値を正規表現で追うと、値の中の語を宛先と取り違える）。
# 出力は local（宛先がすべてローカル）・none（curl の起動が無い）・それ以外（ask の理由）の 1 行。
# python3 が落ちたときは ask に倒す（素通しにするとガードが黙って開く）。
# プログラムはコマンド置換の外で読む。bash 3.2 は $(...) の中のヒアドキュメントにあるバッククォートで
# 構文エラーになり、hook 全体が何も出さずに終わる（= 全件素通し）
read -r -d '' CLASSIFY <<'PY' || true
import os, re, shlex

# 値を取るオプション。値を宛先と数えないために飛ばす
SHORT_VALUE = set("AbcCdDeEFHmoPQrtTuUwXyYz")
LONG_VALUE = {
    "--data", "--data-ascii", "--data-binary", "--data-raw", "--data-urlencode", "--json",
    "--header", "--proxy-header", "--request", "--user", "--user-agent", "--referer",
    "--output", "--output-dir", "--upload-file", "--dump-header", "--cookie", "--cookie-jar",
    "--form", "--form-string", "--write-out", "--max-time", "--connect-timeout", "--retry",
    "--retry-delay", "--retry-max-time", "--range", "--continue-at", "--cacert", "--capath",
    "--cert", "--key", "--cert-type", "--key-type", "--pass", "--oauth2-bearer",
    "--interface", "--local-port", "--limit-rate", "--max-filesize", "--max-redirs",
    "--trace", "--trace-ascii", "--stderr", "--unix-socket", "--abstract-unix-socket",
    "--aws-sigv4", "--variable", "--expect100-timeout", "--keepalive-time", "--quote",
    "--happy-eyeballs-timeout-ms", "--time-cond", "--speed-limit", "--speed-time",
}
# 宛先をローカルの外へ向け直せるオプション（-x と -K は短い形もある）
REDIRECT = {"--proxy", "--preproxy", "--socks4", "--socks4a", "--socks5", "--socks5-hostname",
            "--connect-to", "--resolve", "--config", "--doh-url", "--dns-servers"}
SHORT_REDIRECT = {"x": "--proxy", "K": "--config"}
# 後ろに別のコマンドを取るコマンド。この後の curl も起動として扱う
WRAPPERS = {"sudo", "env", "command", "exec", "time", "nohup", "nice", "xargs", "watch",
            "timeout", "gtimeout", "caffeinate"}
SEPARATORS = {";", "&", "&&", "|", "||", "(", ")", "\n"}

def is_local(host):
    host = host.lower().strip("[]")
    return (host == "localhost" or host.endswith(".localhost")
            or re.fullmatch(r"127(\.\d{1,3}){3}", host) is not None
            or host in ("::1", "0.0.0.0"))

def host_of(target):
    # scheme・userinfo・パスを外して host を取る。$ や glob を含む host は解決できないので None
    rest = re.sub(r"^[A-Za-z][A-Za-z0-9+.-]*://", "", target)
    rest = re.split(r"[/?#]", rest, maxsplit=1)[0]
    # userinfo の @ が 2 つ以上あると、どこまでを userinfo と読むかが実装で割れる
    if rest.count("@") > 1:
        return None
    rest = rest.rsplit("@", 1)[-1]
    if rest.startswith("["):
        host = rest.split("]", 1)[0] + "]"
    else:
        host = rest.split(":", 1)[0]
    if not host or re.search(r"[$`{}\[\]*?]", host.strip("[]") if host.startswith("[") else host):
        return None
    return host

def check_curl(args):
    # curl の引数を読み、ask の理由を返す（問題が無ければ None）
    targets, i = [], 0
    while i < len(args):
        a = args[i]
        if a == "--":
            targets.extend(args[i + 1:])
            break
        if a.startswith("--"):
            name, eq, value = a.partition("=")
            if name in REDIRECT:
                return f"curl の {name} は宛先をローカルの外へ向け直せます"
            if name == "--url":
                if eq:
                    targets.append(value)
                elif i + 1 < len(args):
                    targets.append(args[i + 1]); i += 1
            elif name in LONG_VALUE and not eq:
                i += 1
        elif a.startswith("-") and len(a) > 1:
            for j, ch in enumerate(a[1:], start=1):
                if ch in SHORT_REDIRECT:
                    return f"curl の -{ch}（{SHORT_REDIRECT[ch]}）は宛先をローカルの外へ向け直せます"
                if ch in SHORT_VALUE:
                    if j == len(a) - 1:
                        i += 1
                    break
        else:
            targets.append(a)
        i += 1
    for t in targets:
        h = host_of(t)
        if h is None:
            return f"curl の宛先 {t} の host を特定できません"
        if not is_local(h):
            return f"curl の宛先 {t} が localhost 以外です"
    return None

def scan(cmd, depth=0):
    # 戻り値: (curl を見つけたか, ask の理由 or None)
    if depth > 4:
        return True, "curl を含むコマンドの入れ子が深すぎて解析できません"
    cmd = cmd.replace("`", " ; ").replace("$(", " ; ( ")
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    tokens = list(lex)
    found = False
    # コマンドごとに区切る
    # リダイレクト（> out.txt・2>&1・&>log）は演算子と行き先を落とす。残すと行き先のファイル名を宛先と数える
    segments, cur, skip = [], [], False
    for t in tokens:
        if skip:
            skip = False
        elif re.fullmatch(r"[<>&]*[<>][<>&]*", t):
            if cur and cur[-1].isdigit():
                cur.pop()
            skip = True
        elif t in SEPARATORS or set(t) <= set(";&|()"):
            segments.append(cur); cur = []
        else:
            cur.append(t)
    segments.append(cur)
    for seg in segments:
        k = 0
        # 先頭の代入を飛ばしてコマンド名に着く
        while k < len(seg) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", seg[k]):
            k += 1
        names = [os.path.basename(w) for w in seg]
        head = names[k] if k < len(seg) else ""
        if head == "curl":
            found = True
            reason = check_curl(seg[k + 1:])
            if reason:
                return True, reason
        # sudo -u root curl …・timeout -s KILL 5 curl … のように、ラッパーは値を取るオプションを持つので、
        # オプションを読み飛ばしてコマンド名を探さず、最初の curl を起動とみなす（見落とすとガードが開く）
        elif head in WRAPPERS and "curl" in names[k:]:
            found = True
            if "xargs" in names[k:names.index("curl", k)]:
                return True, "xargs で起動する curl は宛先が標準入力から決まります"
            reason = check_curl(seg[names.index("curl", k) + 1:])
            if reason:
                return True, reason
        # find -exec curl … のように、引数の位置から curl を起動するもの
        elif head == "find" and "curl" in names:
            found = True
            idx = names.index("curl")
            end = next((n for n in range(idx, len(seg)) if seg[n] in (";", "+", "{}")), len(seg))
            reason = check_curl([w for w in seg[idx + 1:end] if w != "{}"])
            if reason:
                return True, reason
        # bash -c "curl …"・ssh host "curl …" のように、引用の中に別のコマンド列があるもの
        for w in seg:
            if w != "curl" and re.search(r"(^|[^A-Za-z0-9_-])curl([^A-Za-z0-9_-]|$)", w) and re.search(r"\s|`|\$\(", w):
                f, reason = scan(w, depth + 1)
                found = found or f
                if reason:
                    return True, reason
    return found, None

try:
    found, reason = scan(os.environ["CMD"])
except ValueError as e:
    print(f"curl を含むコマンドを解析できません（{e}）")
else:
    print(reason if reason else ("local" if found else "none"))
PY
if ! verdict=$(CMD="$COMMAND" python3 -c "$CLASSIFY" 2>/dev/null); then
  verdict="curl を含むコマンドの判定に失敗しました"
fi

if [[ "$verdict" != "local" && "$verdict" != "none" ]]; then
  decide_ask_or_deny "${verdict}。外部への curl は事前にユーザー確認が必要です（localhost・127.0.0.0/8・::1 宛ては確認なしで通します）。"
  # opt-in trace: CLAUDE_CODE_HOOK_TRACE 環境変数が定義されている時のみログ出力
  if [[ -n "${CLAUDE_CODE_HOOK_TRACE:-}" ]]; then
    mkdir -p ~/.claude/logs
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $(basename "$0") matched=true decision=${LAST_DECISION:-ask}" >> ~/.claude/logs/hook-trace.log
  fi
fi

exit 0
