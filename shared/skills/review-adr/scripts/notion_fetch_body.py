"""会話の記録から、今回の notion-fetch の結果の本文と属性を要約せずに取り出す。

モデルが Write で本文を写すと、長い本文が要約・抜粋になる。Claude Code の会話の記録
（jsonl）には notion-fetch の結果がそのまま残るので、そこから機械的に取り出す。

使い方:
  python3 notion_fetch_body.py --page <URL か ID> --cwd <対象 repo>
      --since <UTC の時刻> --out <本文の書き先> --props-out <属性の書き先>

候補は、tool_use の timestamp が --since 以降で、input.id のページ ID が一致し、
対応する tool_result が JSON として読めて <content> を持つものだけ。そのうち最も
新しいものを採る。--since で今回の呼び出しに限るのは、過去のセッションの古い版を
rc=0 で黙って使わないため。

記録の場所: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/<cwd の英数字以外を - に>/
の下の *.jsonl（サブエージェントの <session>/subagents/*.jsonl を含む）。

終了コード: 0 = 書いた / 1 = 候補が無い（どちらのファイルも作らない）/ 2 = 引数の誤り
"""
import argparse
import datetime
import glob
import json
import os
import re
import sys

PROG = "notion_fetch_body.py"
HEX32 = re.compile(r"([0-9a-f]{32})$")


class UsageError(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)


def page_id(value):
    """URL か ID から、ハイフンを除いた 32 桁の 16 進を返す。読めなければ None"""
    v = value.strip().lower().split("?")[0].split("#")[0]
    v = v.rstrip("/").replace("-", "")
    m = HEX32.search(v)
    return m.group(1) if m else None


def parse_time(value):
    """ISO 8601 の UTC 時刻（小数秒の有無・Z と +00:00 を吸収）。読めなければ None"""
    if not isinstance(value, str):
        return None
    v = value.strip()
    if v.endswith("Z"):
        v = v[:-1] + "+00:00"
    m = re.match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?([+-]\d{2}:\d{2})$", v)
    if not m:
        return None
    frac = (m.group(2) or ".0")[1:7].ljust(6, "0")
    try:
        t = datetime.datetime.strptime(m.group(1) + m.group(3).replace(":", ""),
                                       "%Y-%m-%dT%H:%M:%S%z")
    except ValueError:
        return None
    return t.replace(microsecond=int(frac))


def transcript_dir(cwd):
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(
        os.path.expanduser("~"), ".claude")
    name = re.sub(r"[^A-Za-z0-9]", "-", os.path.abspath(cwd))
    return os.path.join(base, "projects", name)


def result_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for x in content:
            if isinstance(x, dict) and isinstance(x.get("text"), str):
                parts.append(x["text"])
        return "".join(parts)
    return None


def between(text, start, end):
    i = text.find(start)
    j = text.rfind(end)
    if i < 0 or j < i:
        return None
    return text[i + len(start):j]


def blocks(line):
    try:
        o = json.loads(line)
    except ValueError:
        return None, []
    if not isinstance(o, dict):
        return None, []
    msg = o.get("message")
    content = msg.get("content") if isinstance(msg, dict) else None
    if not isinstance(content, list):
        return o, []
    return o, [b for b in content if isinstance(b, dict)]


def scan_file(path, want, since, found):
    uses = {}
    try:
        f = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return
    with f:
        for line in f:
            o, bs = blocks(line)
            for b in bs:
                if b.get("type") == "tool_use":
                    name = b.get("name")
                    if not (isinstance(name, str) and name.endswith("notion-fetch")):
                        continue
                    inp = b.get("input")
                    raw = inp.get("id") if isinstance(inp, dict) else None
                    t = parse_time(o.get("timestamp"))
                    if not isinstance(raw, str) or t is None or t < since:
                        continue
                    if page_id(raw) == want:
                        uses[b.get("id")] = t
                elif b.get("type") == "tool_result" and b.get("tool_use_id") in uses:
                    text = result_text(b.get("content"))
                    try:
                        body = json.loads(text)["text"] if text else None
                    except (ValueError, KeyError, TypeError):
                        body = None
                    if not isinstance(body, str):
                        continue
                    content = between(body, "<content>", "</content>")
                    if content is None:
                        continue
                    props = between(body, "<properties>", "</properties>") or ""
                    found.append((uses[b.get("tool_use_id")], content, props))


def main(argv):
    ap = Parser(prog=PROG)
    for opt in ("--page", "--cwd", "--since", "--out", "--props-out"):
        ap.add_argument(opt, required=True)
    try:
        a = ap.parse_args(argv[1:])
    except UsageError as e:
        sys.stderr.write(PROG + ": 引数の誤り: " + str(e) + "\n")
        return 2
    want = page_id(a.page)
    if want is None:
        sys.stderr.write(PROG + ": ページ ID を読めない: " + a.page + "\n")
        return 2
    since = parse_time(a.since)
    if since is None:
        sys.stderr.write(PROG + ": --since を読めない（例 2026-11-24T03:00:00Z）: "
                         + a.since + "\n")
        return 2

    d = transcript_dir(a.cwd)
    files = glob.glob(os.path.join(d, "*.jsonl"))
    files += glob.glob(os.path.join(d, "*", "subagents", "*.jsonl"))
    found = []
    for p in sorted(files):
        scan_file(p, want, since, found)
    if not found:
        sys.stderr.write(PROG + ": --since 以降の notion-fetch の結果が無い（"
                         + want + "・" + d + "）\n")
        return 1
    found.sort(key=lambda x: x[0])
    _, content, props = found[-1]
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(content)
    with open(a.props_out, "w", encoding="utf-8") as f:
        f.write(props)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
