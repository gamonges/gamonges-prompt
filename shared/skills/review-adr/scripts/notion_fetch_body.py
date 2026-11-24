"""会話の記録から、今回の notion-fetch の結果の本文と属性を要約せずに取り出す。

モデルが Write で本文を写すと、長い本文が要約・抜粋になる。Claude Code の会話の記録
（jsonl）には notion-fetch の結果がそのまま残るので、そこから機械的に取り出す。

使い方:
  python3 notion_fetch_body.py --page <URL か ID> --session "$CLAUDE_CODE_SESSION_ID"
      --since <UTC の時刻> --out <本文の書き先> --props-out <属性の書き先>

候補は、tool_use の timestamp が --since 以降で、input.id のページ ID が一致し、
対応する tool_result が JSON として読めて、空白だけでない <content> を持つものだけ。そのうち最も
新しいものを採る。--since で今回の呼び出しに限るのは、過去のセッションの古い版を
rc=0 で黙って使わないため。

記録の場所: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/*/<session>.jsonl と
projects/*/<session>/subagents/*.jsonl（今回のセッションとそのサブエージェント）だけ。
セッション ID で絞るのは、同じ worktree の別のチャットが同じページを開くと候補が混ざる
ため（--since だけでは防げない）。project ディレクトリは * で探すので、cwd の名前の付け方
（サブディレクトリからの起動・symlink の cwd）に依らない。tool_use の ID はモデルから
見えないので使わない。

終了コード: 0 = 書いた / 1 = 候補が無い・セッション ID が空（どちらのファイルも作らない）
/ 2 = 引数の誤り・書き込みの失敗（どちらのファイルも残さない）
"""
import argparse
import datetime
import glob
import json
import os
import re
import sys
from urllib.parse import parse_qs, urlsplit

PROG = "notion_fetch_body.py"
HEX32 = re.compile(r"([0-9a-f]{32})$")


class UsageError(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)


def page_id(value):
    """URL か ID から、ハイフンを除いた 32 桁の 16 進を返す。読めなければ None

    peek 形式（DB の表から開いた `<DB>?v=<view>&p=<page>`）では、? の前は DB の ID なので
    p= を採る（? の前を採ると、同じ DB の全ページが一致する）。
    """
    v = value.strip().lower()
    # keep_blank_values: 値が空の p= も「p= があるのに読めない」として扱う（既定では捨てられ、DB の ID に落ちる）
    ps = parse_qs(urlsplit(v).query, keep_blank_values=True).get("p")
    if ps is not None:
        # p= があるのに読めなければ、? の前（DB の ID）に落とさず読めない扱いにする
        m = HEX32.search(ps[0].replace("-", ""))
        return m.group(1) if m else None
    v = v.split("?")[0].split("#")[0]
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


SESSION = re.compile(r"^[A-Za-z0-9_-]+$")


def transcript_files(session):
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(
        os.path.expanduser("~"), ".claude")
    projects = os.path.join(base, "projects")
    files = glob.glob(os.path.join(projects, "*", session + ".jsonl"))
    files += glob.glob(os.path.join(projects, "*", session, "subagents", "*.jsonl"))
    return projects, files


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


def between(text, start, end, last=True):
    """start と end の間。last=False なら start の後の最初の end まで"""
    i = text.find(start)
    if i < 0:
        return None
    j = text.rfind(end) if last else text.find(end, i + len(start))
    if j < i:
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
                    # 本文は最後の </content> まで（本文の中の文字列 </content> に引きずられない）。
                    # 属性は本文より前にあるので最初の </properties> まで
                    content = between(body, "<content>", "</content>")
                    if content is None or not content.strip():
                        continue
                    props = between(body, "<properties>", "</properties>", last=False) or ""
                    found.append((uses[b.get("tool_use_id")], content, props))


def main(argv):
    ap = Parser(prog=PROG)
    for opt in ("--page", "--session", "--since", "--out", "--props-out"):
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

    if a.session == "":
        sys.stderr.write(PROG + ": セッション ID が無い（CLAUDE_CODE_SESSION_ID が空）\n")
        return 1
    if not SESSION.match(a.session):
        sys.stderr.write(PROG + ": セッション ID を読めない: " + a.session + "\n")
        return 2
    d, files = transcript_files(a.session)
    found = []
    for p in sorted(files):
        scan_file(p, want, since, found)
    if not found:
        sys.stderr.write(PROG + ": --since 以降の notion-fetch の結果が無い（"
                         + want + "・" + d + "/*/" + a.session + "）\n")
        return 1
    found.sort(key=lambda x: x[0])
    _, content, props = found[-1]
    return publish(a.out, content, a.props_out, props)


def publish(out, content, props_out, props):
    """一時ファイルに書いてから両方を置き換える。失敗したら何も残さず rc=2

    os.replace は 1 ファイルずつなので、属性の置き換えだけが失敗したら、先に置き換えた
    本文を消して巻き戻す（rc=2 で本文だけが残ると、呼び出し側が片方だけで組み立てる）。
    """
    tmps = [out + ".tmp", props_out + ".tmp"]
    replaced = False
    try:
        for path, text in zip(tmps, (content, props)):
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
        os.replace(tmps[0], out)
        replaced = True
        os.replace(tmps[1], props_out)
    except (OSError, UnicodeError) as e:
        # UnicodeError: 本文に単独のサロゲートがあると UTF-8 で書けない。traceback で終わると
        # rc=1（候補なし）と見分けがつかず、一時ファイルも残る
        for path in tmps + ([out] if replaced else []):
            try:
                os.remove(path)
            except OSError:
                pass
        sys.stderr.write(PROG + ": 書き込めない: " + str(e) + "\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
