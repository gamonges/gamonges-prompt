#!/usr/bin/env python3
"""series-run の横断の受信箱。登録簿の足し引きと、集約ビュー（HTML）の生成。

I/F と呼び出す時点の正典は ../reference/inbox.md。ここに書くのは実装上の判断だけ。

ビューは各シリーズの状態ファイル（series-run.md）から決定的に導ける写しで、正本ではない。
3 つの coordinator が出来事のたびに作り直すので、LLM で生成せずこのスクリプトで作る。

/usr/bin/python3（3.9）でも動かすため、標準ライブラリだけを使い、match 文や
`X | None` の注釈を使わない。3.9 は約 1,000 バイトを超える日本語の行で偽の
Non-UTF-8 エラーを出すので、メッセージは短い行に分ける。
"""

import argparse
import datetime
import fcntl
import hashlib
import html
import json
import os
import re
import sys
import tempfile
import urllib.parse

DONE_STATES = ("完了", "対象外")
SECTION_UNITS = "作業単位"
SECTION_LIST = "ユーザー向け: 質問と回答の一覧"
SUB_WAITING = "待っているもの"
SUB_ANSWERED = "答えが出たもの"
AUTO_MARK = "推奨で進めた"

FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
URL_RE = re.compile(r"https?://[^\s<>\"'）」]+")


def state_dir():
    # テストが HOME を差し替えずに置き場所を変えられるよう、環境変数を先に見る
    d = os.environ.get("SERIES_RUN_STATE_DIR")
    if d:
        return d
    return os.path.join(os.path.expanduser("~"), ".local", "state", "series-run")


def registry_dir():
    return os.path.join(state_dir(), "registry")


def entry_path(state):
    # 1 シリーズ 1 ファイル。書き手がその coordinator だけに決まるので、登録簿にロックが要らない。
    # キーは realpath（/tmp と /private/tmp のような表記の違いで同じシリーズを 2 件にしない）
    key = hashlib.sha1(os.path.realpath(state).encode("utf-8")).hexdigest()[:16]
    return os.path.join(registry_dir(), key + ".json")


def drop_other_keys(state):
    """同じ状態ファイルを指すのにキーが今のものと違う登録（旧形式の abspath のキー・別の表記）を消す。
    読めない登録は消さない（render で「読めない」と出す）"""
    reg, real, keep = registry_dir(), os.path.realpath(state), os.path.basename(entry_path(state))
    if not os.path.isdir(reg):
        return
    for name in os.listdir(reg):
        if not name.endswith(".json") or name == keep:
            continue
        try:
            entry = load_entry(os.path.join(reg, name))
        except (OSError, ValueError):
            continue
        if os.path.realpath(entry["state"]) == real:
            os.remove(os.path.join(reg, name))


def load_entry(path):
    with open(path, encoding="utf-8") as f:
        entry = json.load(f)
    # 描画に使う欄の型も確かめる。title が数値・terminal が null だと html.escape で AttributeError になり、
    # シリーズ単位の隔離を抜けて全体の更新が止まる
    ok = (isinstance(entry, dict) and isinstance(entry.get("state"), str) and entry["state"]
          and isinstance(entry.get("title", ""), str) and isinstance(entry.get("terminal", ""), str))
    if not ok:
        raise ValueError("登録 %s の形が違います" % os.path.basename(path))
    return entry


def atomic_write(path, text):
    # 開いたままのビュー・ほかの coordinator が書きかけを読まないよう、置き換えで書く
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".inbox-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            # 登録簿は正本なので、置き換えの前に中身を確かに書く
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


# ---------------------------------------------------------------- 状態ファイルの解析

def outside_fences(lines):
    """行ごとに、コードの囲みの外なら True（囲みの行そのものは False）。

    series_sync.py の scan_fences と同じ考え方（skill をまたいだ import は
    インストール先のパスに依存するので写す）。閉じていない囲みは全部を外とみなす。
    """
    result = []
    fence = None
    for line in lines:
        if fence is None:
            m = FENCE_RE.match(line)
            if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
                fence = m.group(1)
            result.append(fence is None)
        else:
            m = FENCE_RE.match(line)
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) \
                    and m.group(2).strip() == "":
                fence = None
            result.append(False)
    if fence is not None:
        return [True] * len(lines)
    return result


def section(lines, outside, prefix, name, start=0, end=None):
    """囲みの外の見出し `<prefix> <name>` の本文の行（次の同じ深さ以上の見出しの前まで）。"""
    end = len(lines) if end is None else end
    level = len(prefix)
    begin = None
    for i in range(start, end):
        if not outside[i]:
            continue
        m = re.match(r"^(#{1,6}) (.*)$", lines[i])
        if not m:
            continue
        if begin is not None and len(m.group(1)) <= level:
            return begin, i
        if begin is None and m.group(1) == prefix and m.group(2).strip() == name:
            begin = i + 1
    if begin is None:
        return None
    return begin, end


def parse_units(lines, outside):
    span = section(lines, outside, "##", SECTION_UNITS)
    units = []
    if span is None:
        return units
    for i in range(*span):
        line = lines[i].strip()
        if not outside[i] or not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if not cells or cells[0] == "worktree" or set("".join(cells)) <= set("-: "):
            continue
        cells += [""] * (5 - len(cells))
        units.append({"worktree": cells[0], "stage": cells[1], "where": cells[2],
                      "waiting_on": cells[3], "next": cells[4]})
    return units


def parse_list(lines, outside):
    span = section(lines, outside, "##", SECTION_LIST)
    if span is None:
        return [], []
    waiting = section(lines, outside, "###", SUB_WAITING, *span)
    answered = section(lines, outside, "###", SUB_ANSWERED, *span)
    w = [lines[i] for i in range(*waiting)] if waiting else []
    a = [lines[i] for i in range(*answered)] if answered else []
    return strip_blank(w), [line for line in a if AUTO_MARK in line]


def strip_blank(lines):
    while lines and not lines[0].strip():
        lines = lines[1:]
    while lines and not lines[-1].strip():
        lines = lines[:-1]
    return lines


def read_series(entry):
    """登録の 1 件を、ビューに出す形にする。状態ファイルが読めない（壊れた）なら例外のまま上げる。"""
    state = entry["state"]
    item = {"title": entry.get("title") or state, "terminal": entry.get("terminal", ""),
            "state": state, "done": None, "waiting": [], "auto": [], "units": []}
    if not os.path.exists(state):
        item["done"] = "状態ファイルが無い"
        return item
    with open(state, encoding="utf-8") as f:
        lines = f.read().split("\n")
    outside = outside_fences(lines)
    item["units"] = parse_units(lines, outside)
    item["waiting"], item["auto"] = parse_list(lines, outside)
    # 完了の後に残る依頼（④）があるうちは、終わったことにせず待っているものを出す
    if item["units"] and all(u["where"] in DONE_STATES for u in item["units"]) and not item["waiting"]:
        item["done"] = "全作業単位が完了か対象外"
    return item


# ---------------------------------------------------------------- 描画

CSS = """
:root { --bg: #ffffff; --fg: #1f2328; --muted: #59636e; --line: #d1d9e0;
  --card: #f6f8fa; --mark: #fff8c5; --link: #0969da; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #0d1117; --fg: #e6edf3; --muted: #9198a1; --line: #3d444d;
    --card: #151b23; --mark: #4d3b00; --link: #4493f8; }
}
body { background: var(--bg); color: var(--fg); margin: 0 auto; max-width: 960px;
  padding: 16px; font: 15px/1.6 -apple-system, "Hiragino Sans", sans-serif; }
a { color: var(--link); }
section { border: 1px solid var(--line); border-radius: 8px; background: var(--card);
  margin: 16px 0; padding: 12px 16px; }
section.done { color: var(--muted); }
h1 { font-size: 20px; } h2 { font-size: 17px; margin: 4px 0; } h3 { font-size: 15px; }
.meta { color: var(--muted); font-size: 13px; }
pre { white-space: pre-wrap; overflow-wrap: anywhere; margin: 0;
  font: 14px/1.6 ui-monospace, Menlo, monospace; }
mark { background: var(--mark); color: inherit; }
table { border-collapse: collapse; width: 100%; font-size: 14px; }
th, td { border-bottom: 1px solid var(--line); padding: 4px 6px; text-align: left;
  vertical-align: top; overflow-wrap: anywhere; }
"""


def text_html(s):
    # 本文の URL はリンクにする（ビューは外部を読み込まないので、URL が出るのはリンクの中だけ）
    out, pos = [], 0
    for m in URL_RE.finditer(s):
        out.append(html.escape(s[pos:m.start()]))
        u = html.escape(m.group(0))
        out.append('<a href="%s">%s</a>' % (u, u))
        pos = m.end()
    out.append(html.escape(s[pos:]))
    return "".join(out)


def card_link(worktree):
    path = os.path.join(worktree, "tmp", "meaning-card.html")
    if worktree and os.path.isabs(worktree) and os.path.exists(path):
        # 空白・# を含むパスでもリンクが切れないよう、パスを URL の形に直す
        return '<a href="file://%s">カード</a>' % html.escape(urllib.parse.quote(path))
    return ""


def render_series(item):
    esc = html.escape
    head = ('<h2>%s</h2>\n<p class="meta">答える terminal: <code>%s</code>'
            ' ・ 状態ファイル: <code>%s</code></p>\n'
            % (esc(item["title"]), esc(item["terminal"]), esc(item["state"])))
    if item.get("broken"):
        return '<section>\n%s<p><mark>読めない: %s</mark></p>\n</section>\n' % (head, esc(item["broken"]))
    if item["done"]:
        return ('<section class="done">\n%s<p>終わった（登録が残っている）: %s</p>\n</section>\n'
                % (head, esc(item["done"])))
    parts = ['<section>\n', head, "<h3>待っているもの</h3>\n"]
    if item["waiting"]:
        parts.append("<pre>%s</pre>\n" % "\n".join(text_html(x) for x in item["waiting"]))
    else:
        parts.append("<p>待っているものは無い</p>\n")
    if item["auto"]:
        parts.append("<h3>推奨で進めたもの（確かめるか覆すなら番号で答える）</h3>\n<pre>")
        parts.append("\n".join("<mark>%s</mark>" % text_html(x) for x in item["auto"]))
        parts.append("</pre>\n")
    parts.append("<h3>作業単位</h3>\n<table>\n<tr><th>段</th><th>現在地</th>"
                 "<th>待っている相手</th><th>次</th><th>意味のカード</th></tr>\n")
    for u in item["units"]:
        parts.append("<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n"
                     % (esc(u["stage"]), esc(u["where"]), esc(u["waiting_on"]),
                        text_html(u["next"]), card_link(u["worktree"])))
    parts.append("</table>\n</section>\n")
    return "".join(parts)


def question_count(item):
    # 待っているものの件数は「- 」で始まる行の数（複数行の 1 問を、行の数だけ数えない）
    return sum(1 for line in item["waiting"] if line.startswith("- "))


def render_html(items, now):
    # 読めないものと待っているものが多いシリーズを上に、終わったものを下に置く（並びを決定的にする）
    items = sorted(items, key=lambda x: (x["done"] is not None, x.get("broken") is None,
                                         -question_count(x), x["title"]))
    body = "".join(render_series(x) for x in items) or "<p>登録されたシリーズは無い</p>\n"
    return ('<!doctype html>\n<html lang="ja">\n<head>\n<meta charset="utf-8">\n'
            '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
            '<meta http-equiv="refresh" content="60">\n'
            '<title>series-run の受信箱</title>\n<style>%s</style>\n</head>\n<body>\n'
            '<h1>series-run の受信箱</h1>\n<p class="meta">更新: %s（60 秒ごとに読み直す）</p>\n'
            '%s</body>\n</html>\n' % (CSS, html.escape(now), body))


# ---------------------------------------------------------------- コマンド

def cmd_register(args):
    os.makedirs(registry_dir(), exist_ok=True)
    drop_other_keys(args.state)
    entry = {"state": os.path.realpath(args.state), "terminal": args.terminal,
             "title": args.title,
             "registered_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds")}
    atomic_write(entry_path(args.state), json.dumps(entry, ensure_ascii=False, indent=2) + "\n")
    return 0


def cmd_unregister(args):
    try:
        os.remove(entry_path(args.state))
    except FileNotFoundError:
        pass
    drop_other_keys(args.state)
    return 0


def cmd_render(args):
    d = state_dir()
    os.makedirs(d, exist_ok=True)
    out = os.path.join(d, "inbox.html")
    # 読み取りから置き換えまでを排他にする。置き換えだけを囲むと、古い状態を読んだ render が
    # 後から置き換えてビューが巻き戻る
    with open(os.path.join(d, "inbox.lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            items, errors = [], []
            reg = registry_dir()
            names = sorted(os.listdir(reg)) if os.path.isdir(reg) else []
            for name in names:
                if not name.endswith(".json"):
                    continue
                # 1 シリーズの壊れで全シリーズのビューを止めない（coordinator の Write は原子的でないので、
                # 書き込み中の読み取りで起こりうる）。読めないものは「読めない」と出し、失敗を返す
                entry = {"title": name, "terminal": "", "state": os.path.join(reg, name)}
                try:
                    entry = load_entry(os.path.join(reg, name))
                    items.append(read_series(entry))
                except (OSError, ValueError) as e:
                    errors.append("%s: %s" % (name, e))
                    # 登録が読めていれば、題名と答える terminal を出す（どこで直すかが分かる）
                    items.append({"title": entry.get("title") or entry["state"], "terminal": entry.get("terminal", ""),
                                  "state": entry["state"], "done": None, "broken": str(e),
                                  "waiting": [], "auto": [], "units": []})
            now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
            atomic_write(out, render_html(items, now))
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)
    print(out)
    for e in errors:
        sys.stderr.write("series_inbox.py: render: 読めない登録 %s\n" % e)
    return 1 if errors else 0


def main(argv):
    p = argparse.ArgumentParser(description="series-run の横断の受信箱")
    sub = p.add_subparsers(dest="cmd")
    r = sub.add_parser("register")
    r.add_argument("--state", required=True)
    r.add_argument("--terminal", required=True)
    r.add_argument("--title", required=True)
    u = sub.add_parser("unregister")
    u.add_argument("--state", required=True)
    sub.add_parser("render")
    args = p.parse_args(argv)
    handlers = {"register": cmd_register, "unregister": cmd_unregister, "render": cmd_render}
    if args.cmd not in handlers:
        p.print_usage(sys.stderr)
        return 1
    try:
        return handlers[args.cmd](args)
    except (OSError, ValueError) as e:
        # UnicodeDecodeError・json の壊れも ValueError。ビューは写しなので、失敗を返して監督は続ける
        sys.stderr.write("series_inbox.py: %s: %s\n" % (args.cmd, e))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
