#!/usr/bin/env python3
"""シリーズの契約 series.md を検査・描画し、各 PR の本文の全体像を同期する。

契約の正典は ../reference/series-format.md。ここに書くのは実装上の判断だけ。

/usr/bin/python3（3.9）でも動かすため、標準ライブラリだけを使い、match 文や
`X | None` の注釈を使わない。3.9 は約 1,000 バイトを超える日本語の行で偽の
Non-UTF-8 エラーを出すので、メッセージは短い行に分ける。
"""

import argparse
import datetime
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

BEGIN = "<!-- series-overview:begin -->"
END = "<!-- series-overview:end -->"
# 異体字セレクタ U+FE0F の有無に依らず拾うため、地図の絵文字 U+1F5FA までで判定する
HEADING_PREFIX = "## \U0001F5FA"
BODY_LIMIT = 65536
# status が未登録の PR を探す件数の上限（gh pr list --limit）
PR_LIST_LIMIT = 100

STAGE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
STEP_ID_RE = re.compile(r"^[A-Za-z]+-?[0-9]+[a-z]?$")
STEP_NUM_RE = re.compile(r"^[0-9]+$")
PLACEHOLDER_RE = re.compile(r"\{\{([^{}]*)\}\}")
# 行頭のノードの定義だけを拾う。辺の行（A --> B["…"]）の中の定義は拾わない
NODE_DEF_RE = re.compile(r"^\s*([A-Za-z][A-Za-z0-9_]*)\s*[\[\(\{>]")
FENCE_RE = re.compile(r"^(`{3,}|~{3,})(.*)$")

STAGE_COLUMNS = ["段", "リポジトリ", "含むステップ", "base", "順序",
                 "worktree", "ブランチ", "PR"]
PROGRESS_HEADER = ("| 段 | リポジトリ | PR | 状態 | レビュー"
                   " | 未解決スレッド | ブランチ |")

MSG_HEADING_ONLY = ("heading-only: 目印の無い全体像がある。"
                    "--migrate で置き換えられる")
MSG_MARKERS = "markers: 目印が 1 組でない（手で直す）"
MSG_MIGRATE = ("migrate: 全体像の見出しの後に --- の行が無いか、"
               "間に別の ## 見出しがある")
MSG_TOO_LONG = "too-long: 置き換えた本文が 65536 字を超える"


class SeriesError(Exception):
    pass


class BodyError(Exception):
    pass


# ---------------------------------------------------------------- 解析

def split_lines(text):
    return text.split("\n")


def fence_open(line):
    """囲みの開始の行なら囲みの印（``` や ~~~）を、でなければ None を返す。

    CommonMark では、バッククォートの囲みの info string はバッククォートを含められない
    （```foo``` で始まる行はインラインのコードで、囲みを開始しない）。
    """
    m = FENCE_RE.match(line)
    if m is None or (m.group(1)[0] == "`" and "`" in m.group(2)):
        return None
    return m.group(1)


def scan_fences(lines):
    """行ごとの「囲みの外か」（囲みの行そのものは False）と、閉じていない囲みの印を返す。"""
    result = []
    fence = None
    for line in lines:
        if fence is None:
            fence = fence_open(line)
            result.append(fence is None)
        else:
            m = FENCE_RE.match(line)
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) \
                    and m.group(2).strip() == "":
                fence = None
            result.append(False)
    return result, fence


def outside_fences(lines):
    """行ごとに、コードの囲みの外なら True（囲みの行そのものは False）。

    本文の終わりまで閉じていない囲みがあれば、すべて True にする（囲みの後ろにある
    既存のブロックを見落として 2 つ目を足すより、囲みの中の目印を数える方が安全なため）。
    """
    result, fence = scan_fences(lines)
    if fence is not None:
        return [True] * len(lines)
    return result


def heading_indexes(lines):
    """コードの囲みの外にある `## ` 見出しの (行番号, 見出し名)。

    完成形の中にも `## 🗺️` があるため、囲みを追わずに数えると節が切れる。
    """
    outside = outside_fences(lines)
    return [(i, line[3:].strip()) for i, line in enumerate(lines)
            if outside[i] and line.startswith("## ")]


def section_span(lines, name):
    """節の本文の範囲 [start, end)（見出しの次の行から次の見出しの前まで）。"""
    heads = heading_indexes(lines)
    for k, (i, title) in enumerate(heads):
        if title == name:
            end = heads[k + 1][0] if k + 1 < len(heads) else len(lines)
            return i + 1, end
    return None


def parse_frontmatter(lines):
    fm = {}
    if not lines or lines[0].strip() != "---":
        return fm, 0
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return fm, i + 1
        if ":" in lines[i]:
            key, _, value = lines[i].partition(":")
            fm[key.strip()] = value.strip()
    return fm, 0


def split_row(line):
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    # GFM の表では、セルの中の | を \| と書く。\| は区切りにせず、セルの文字列のまま持つ
    return [c.strip() for c in re.split(r"(?<!\\)\|", s)]


def parse_table(lines, span):
    """節の中の最初の表を (見出しの列, 行のリスト, 表の範囲) で返す。"""
    if span is None:
        return None
    start, end = span
    i = start
    while i < end and not lines[i].lstrip().startswith("|"):
        i += 1
    if i >= end:
        return None
    j = i
    while j < end and lines[j].lstrip().startswith("|"):
        j += 1
    header = split_row(lines[i])
    rows = [split_row(line) for line in lines[i + 2:j]]
    return header, rows, (i, j)


class Series(object):
    def __init__(self, path, text):
        self.path = path
        self.text = text
        self.lines = split_lines(text)
        self.fm, _ = parse_frontmatter(self.lines)
        self.stages = []
        self.emphasis = {}
        self.template = None
        self.errors = []
        self._parse()

    def _parse(self):
        table = parse_table(self.lines, section_span(self.lines, "段"))
        if table is None:
            self.errors.append("## 段 の表が無い")
        else:
            header, rows, _ = table
            missing = [c for c in STAGE_COLUMNS if c not in header]
            if missing:
                self.errors.append("## 段 の表に列が無い: " + ", ".join(missing))
            else:
                for row in rows:
                    if len(row) > len(header):
                        # 見出しの無いセルは持てず、register・write の書き直しで消えるので止める
                        self.errors.append("## 段 の行のセルが見出しより多い: 段 "
                                           + row[header.index("段")])
                        continue
                    # 必須でない列も行ごとに持つ（register・write が表を書き直すときに消さないため）
                    self.stages.append(dict(zip(header, row + [""] * len(header))))
        table = parse_table(self.lines, section_span(self.lines, "強調"))
        if table is not None:
            _, rows, _ = table
            for row in rows:
                if len(row) < 2:
                    continue
                nodes = [n.strip() for n in row[1].split(",") if n.strip()]
                self.emphasis[row[0]] = nodes
        self.template = extract_template(self.lines)
        if self.template is None:
            self.errors.append("## 全体像 に ````markdown の囲みが無い")

    def stage(self, name):
        for s in self.stages:
            if s["段"] == name:
                return s
        return None


def extract_template(lines):
    span = section_span(lines, "全体像")
    if span is None:
        return None
    start, end = span
    for i in range(start, end):
        if lines[i].startswith("````markdown"):
            for j in range(i + 1, len(lines)):
                if lines[j].rstrip() == "````":
                    return "\n".join(lines[i + 1:j])
            return None
    return None


def load(path):
    with open(path, encoding="utf-8") as f:
        return Series(path, f.read())


def mermaid_nodes(template):
    """mermaid の囲みの中でノードを定義した順の ID。"""
    nodes = []
    inside = False
    for line in split_lines(template):
        if not inside:
            if line.strip().startswith("```mermaid"):
                inside = True
            continue
        if line.strip().startswith("```"):
            inside = False
            continue
        m = NODE_DEF_RE.match(line)
        if m and m.group(1) not in nodes and m.group(1) not in (
                "classDef", "class", "flowchart", "graph", "subgraph", "end"):
            nodes.append(m.group(1))
    return nodes


# ---------------------------------------------------------------- 検査

def duplicate_prs(stages):
    """同じ (リポジトリ, PR) を持つ段の組を、問題の文として返す（register の twin の検査と同じ規則）。"""
    seen = {}
    problems = []
    for s in stages:
        if not s["PR"]:
            continue
        key = (s["リポジトリ"], s["PR"])
        if key in seen:
            problems.append("%s#%s が段 %s と段 %s の 2 つにある"
                            % (key[0], key[1], seen[key], s["段"]))
        else:
            seen[key] = s["段"]
    return problems


def check(series):
    errors = list(series.errors)
    if not series.fm.get("outline"):
        errors.append("frontmatter に outline が無い")
    if scan_fences(series.lines)[1] is not None:
        errors.append("閉じていないコードの囲みがある")
    if section_span(series.lines, "進捗") is None:
        errors.append("## 進捗 の節が無い（status が書く先）")
    names = [s["段"] for s in series.stages]
    for s in series.stages:
        name = s["段"]
        if not STAGE_RE.match(name):
            errors.append("段名が文法に合わない: " + name)
        if not REPO_RE.match(s["リポジトリ"]):
            errors.append("段 %s のリポジトリが owner/repo でない" % name)
        if s["PR"] and not s["PR"].isdigit():
            errors.append("段 %s の PR が数字でない" % name)
    for name in set(names):
        if names.count(name) > 1:
            errors.append("段名が重複している: " + name)
    errors.extend(duplicate_prs(series.stages))
    template = series.template
    if template is None:
        return errors
    first = next((l for l in split_lines(template) if l.strip()), "")
    if not first.startswith(HEADING_PREFIX):
        errors.append("完成形の最初の行が ## 🗺️ 全体像 で始まらない")
    if "series-overview:" in template:
        errors.append("完成形に目印の文字列がある")
    classes = [l for l in split_lines(template) if l.strip() == "{{classes}}"]
    if len(classes) != 1:
        errors.append("{{classes}} の行が 1 つでない（%d 個）" % len(classes))
    elif template.count("{{classes}}") != 1:
        errors.append("{{classes}} が行の途中にある（行単独で書く）")
    for m in PLACEHOLDER_RE.finditer(template):
        token = m.group(1)
        if token in ("this", "classes"):
            continue
        kind, sep, stage = token.partition(":")
        if not sep or kind not in ("pr", "num", "mark", "prcell"):
            errors.append("未知の置換子: {{%s}}" % token)
        elif stage not in names:
            errors.append("置換子が存在しない段を指す: {{%s}}" % token)
    for name in names:
        if "{{mark:%s}}" % name not in template:
            errors.append("段 %s の {{mark:%s}} が無い（表に載らない）"
                          % (name, name))
    defined = mermaid_nodes(template)
    owner = {}
    for stage, nodes in series.emphasis.items():
        if stage not in names:
            errors.append("## 強調 の段が ## 段 に無い: " + stage)
        for node in nodes:
            if node not in defined:
                errors.append("段 %s のノード %s が mermaid の行頭で"
                              "定義されていない" % (stage, node))
            if node in owner and owner[node] != stage:
                errors.append("ノード %s が 2 つの段（%s・%s）にある"
                              % (node, owner[node], stage))
            owner.setdefault(node, stage)
    for name in names:
        if not series.emphasis.get(name):
            errors.append("段 %s の ## 強調 にノードが無い（PR に黄色が出ない）" % name)
    for s in series.stages:
        for step in re.split(r"[・,、\s]+", s["含むステップ"]):
            if STEP_ID_RE.match(step):
                pattern = r"(?<![A-Za-z0-9])%s(?![A-Za-z0-9])" % re.escape(step)
            elif STEP_NUM_RE.match(step):
                # 数字だけでは PR 番号や順序に当たるので、plan.md のステップ名の形で探す
                pattern = r"ステップ\s*%s(?![0-9])" % step
            else:
                continue
            if re.search(pattern, template):
                errors.append("完成形に計画の内部 ID がある: " + step)
    return errors


# ---------------------------------------------------------------- 描画

def short_repo(repo):
    return repo.split("/", 1)[1]


def render_block(series, target):
    t = series.stage(target)
    if t is None:
        raise SeriesError("段が無い: " + target)
    defined = mermaid_nodes(series.template)

    def pr_ref(stage, label):
        s = series.stage(stage)
        if not s["PR"]:
            return None
        if s["リポジトリ"] == t["リポジトリ"]:
            return "#" + s["PR"]
        repo = short_repo(s["リポジトリ"]) if label else s["リポジトリ"]
        return repo + "#" + s["PR"]

    def replace(m):
        token = m.group(1)
        if token == "this":
            return "#" + t["PR"] if t["PR"] else "（未作成）"
        kind, _, stage = token.partition(":")
        if kind == "mark":
            return "👉" if stage == target else ""
        if kind == "num":
            return pr_ref(stage, True) or "未作成"
        ref = pr_ref(stage, False)
        if ref is None:
            return "（未作成）"
        if kind == "prcell" and stage == target:
            return "**" + ref + "**"
        return ref

    out = []
    for line in split_lines(series.template):
        if line.strip() == "{{classes}}":
            indent = line[:len(line) - len(line.lstrip())]
            cur = [n for n in defined if n in series.emphasis.get(target, [])]
            other = [n for n in defined
                     if any(n in nodes for st, nodes in series.emphasis.items()
                            if st != target)]
            if cur:
                out.append("%sclass %s cur" % (indent, ",".join(cur)))
            if other:
                out.append("%sclass %s other" % (indent, ",".join(other)))
            continue
        out.append(PLACEHOLDER_RE.sub(replace, line))
    while out and not out[-1].strip():
        out.pop()
    while out and not out[0].strip():
        out.pop(0)
    return "\n".join([BEGIN] + out + ["", "---", END])


def apply_block(body, block, migrate):
    """本文に全体像のブロックを当てる。(新しい本文, insert|replace|migrate)。

    目印の外はバイト単位で変えない。当てられないときは BodyError。
    """
    body = body or ""
    # 行末を行ごとに保つ（LF と CRLF が混ざった本文でも、目印の外の行末を変えない）。
    # 足すブロックと区切りの行は、本文に CRLF が 1 つでもあれば CRLF にする
    raw = body.splitlines(True)
    eol = "\r\n" if "\r\n" in body else "\n"
    lines = [l.rstrip("\r\n") for l in raw]
    ends_of = [l[len(s):] for l, s in zip(raw, lines)]
    outside = outside_fences(lines)
    begins = [i for i, l in enumerate(lines) if outside[i] and l.strip() == BEGIN]
    ends = [i for i, l in enumerate(lines) if outside[i] and l.strip() == END]
    block_lines = [l + eol for l in block.split("\n")]

    def join(head, mid, tail_from):
        # head は元の行（行末つき）、mid は新しく足す行、tail_from 以降は元の行のまま
        return "".join(raw[:head]) + "".join(mid) + "".join(raw[tail_from:])

    if begins or ends:
        if len(begins) != 1 or len(ends) != 1 or begins[0] > ends[0]:
            raise BodyError(MSG_MARKERS)
        e = ends[0]
        block_end = block_lines[:-1] + [block_lines[-1].rstrip("\r\n") + ends_of[e]]
        result = join(begins[0], block_end, e + 1)
        action = "replace"
    else:
        heads = [i for i, l in enumerate(lines)
                 if outside[i] and l.startswith(HEADING_PREFIX)]
        if heads and not migrate:
            raise BodyError(MSG_HEADING_ONLY)
        if heads:
            h = heads[0]
            stop = None
            # 古い図の mermaid の front-matter（---）や囲みの中の ## では止めない
            for k in range(h + 1, len(lines)):
                if not outside[k]:
                    continue
                if lines[k].strip() == "---":
                    stop = k
                    break
                if lines[k].startswith("## "):
                    break
            if stop is None:
                raise BodyError(MSG_MIGRATE)
            block_end = block_lines[:-1] + [block_lines[-1].rstrip("\r\n") + ends_of[stop]]
            result = join(h, block_end, stop + 1)
            action = "migrate"
        elif body == "":
            result = block.replace("\n", eol)
            action = "insert"
        elif lines[0].startswith("ref "):
            first = raw[0] if ends_of[0] else raw[0] + eol
            if len(lines) > 1 and lines[1].strip() == "":
                # ref の後の空行は目印の外の行なので、空白を含めてそのまま残す
                head = first + raw[1]
                if not ends_of[1]:
                    head += eol
                rest = raw[2:]
            else:
                head = first + eol
                rest = raw[1:]
            result = head + "".join(block_lines) + eol + "".join(rest)
            action = "insert"
        else:
            result = "".join(block_lines) + eol + body
            action = "insert"
    if len(result) > BODY_LIMIT:
        raise BodyError(MSG_TOO_LONG)
    return result, action


# ---------------------------------------------------------------- 書き込み

class Lock(object):
    """series.md の隣の .lock を flock で取る。読み・書き換え・書き込みをこの中で行う。"""

    def __init__(self, path):
        self.path = path + ".lock"
        self.f = None

    def __enter__(self):
        self.f = open(self.path, "a")
        fcntl.flock(self.f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


def atomic_write(path, text):
    # ロックを取らない読み手（check・render・plan）が書きかけを読まないよう、置き換えで書く
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".series-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        # mkstemp は 0600 で作るので、置き換えで元の権限を失わないよう写す
        mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o644
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def read_text(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def format_row(cells):
    return "| " + " | ".join(cells) + " |"


def replace_stage_table(text, stages):
    lines = split_lines(text)
    _, _, (i, j) = parse_table(lines, section_span(lines, "段"))
    header = split_row(lines[i])
    rows = []
    for s in stages:
        rows.append(format_row([s.get(c, "") for c in header]))
    return "\n".join(lines[:i + 2] + rows + lines[j:])


def replace_section(text, name, body_lines):
    lines = split_lines(text)
    span = section_span(lines, name)
    if span is None:
        return text
    start, end = span
    return "\n".join(lines[:start] + body_lines + lines[end:])


def section_lines(text, name):
    lines = split_lines(text)
    span = section_span(lines, name)
    if span is None:
        return None
    return lines[span[0]:span[1]]


def set_frontmatter(text, key, value):
    lines = split_lines(text)
    _, end = parse_frontmatter(lines)
    for i in range(1, max(end - 1, 1)):
        if lines[i].split(":", 1)[0].strip() == key:
            lines[i] = "%s: %s" % (key, value)
            return "\n".join(lines)
    if end:
        lines.insert(end - 1, "%s: %s" % (key, value))
    return "\n".join(lines)


def cmd_register(args):
    # 表のセルに書く値なので、表を壊す文字（| と改行）を受け付けない
    for name, value in (("--branch", args.branch), ("--worktree", args.worktree or "")):
        if "|" in value or "\n" in value:
            print("error: %s に | か改行がある: %s" % (name, value))
            return 1
    if not args.branch.strip():
        # detached HEAD では空になる。空のブランチ列の段すべてに当たるので受け付けない
        print("error: --branch が空")
        return 1
    if not REPO_RE.match(args.repo):
        print("error: --repo が owner/repo でない: " + args.repo)
        return 1
    with Lock(args.series):
        series = load(args.series)
        if series.errors:
            for e in series.errors:
                print("error: " + e)
            return 1
        if args.stage:
            row = series.stage(args.stage)
            if row is None:
                print("error: 段が無い: " + args.stage)
                return 1
            if row["リポジトリ"] != args.repo:
                print("conflict: 段 %s のリポジトリは %s（%s ではない）"
                      % (args.stage, row["リポジトリ"], args.repo))
                return 3
            candidates = [row]
        else:
            same = [s for s in series.stages if s["リポジトリ"] == args.repo]
            candidates = [s for s in same
                          if s["ブランチ"] == args.branch or s["PR"] == str(args.pr)]
            if not candidates:
                candidates = [s for s in same if not s["PR"]]
            if args.worktree:
                narrowed = [s for s in candidates if s["worktree"] == args.worktree]
                if narrowed:
                    candidates = narrowed
        if len(candidates) != 1:
            if not candidates:
                print("ambiguous: 候補なし（%s の空いた段が無い）" % args.repo)
            else:
                print("ambiguous: 段が 1 つに決まらない。候補:")
                for s in candidates:
                    print("  %s %s ブランチ=%s PR=%s" % (
                        s["段"], s["リポジトリ"], s["ブランチ"] or "-",
                        s["PR"] or "-"))
            return 3
        row = candidates[0]
        pr = str(args.pr)
        twin = [s for s in series.stages if s is not row
                and s["リポジトリ"] == args.repo and s["PR"] == pr]
        if twin:
            print("conflict: %s#%s は段 %s に登録済み" % (args.repo, pr, twin[0]["段"]))
            return 3
        if row["PR"] and row["PR"] != pr:
            print("conflict: 段 %s には PR #%s が登録済み" % (row["段"], row["PR"]))
            return 3
        if row["ブランチ"] and row["ブランチ"] != args.branch:
            print("conflict: 段 %s のブランチは %s" % (row["段"], row["ブランチ"]))
            return 3
        before = dict(row)
        row["PR"] = pr
        row["ブランチ"] = args.branch
        if not row["worktree"] and args.worktree:
            row["worktree"] = args.worktree
        label = "段 %s %s#%s" % (row["段"], args.repo, pr)
        if row == before:
            print("unchanged: " + label)
            return 0
        atomic_write(args.series, replace_stage_table(series.text, series.stages))
        print("registered: %s（ブランチ %s）" % (label, args.branch))
        return 0


def cmd_write(args):
    draft = load(args.from_)
    errors = check(draft)
    if errors:
        for e in errors:
            print("error: " + e)
        return 1
    drop = set(args.drop or [])
    with Lock(args.series):
        if not os.path.exists(args.series):
            atomic_write(args.series, draft.text)
            print("written: " + args.series)
            return 0
        cur = load(args.series)
        if cur.errors:
            for e in cur.errors:
                print("error: 今の series.md: " + e)
            return 1
        conflicts = []
        inherited = []
        dropped = []
        reset = []
        for row in draft.stages:
            old = cur.stage(row["段"])
            if old is None:
                continue
            if old["リポジトリ"] != row["リポジトリ"]:
                if old["PR"]:
                    conflicts.append("段 %s のリポジトリが変わった（%s → %s）が、PR %s#%s が登録済み"
                                     % (row["段"], old["リポジトリ"], row["リポジトリ"],
                                        old["リポジトリ"], old["PR"]))
                elif old["ブランチ"]:
                    # 古いリポジトリのブランチなので、新しいリポジトリの行には引き継がない
                    reset.append("段 %s のブランチ %s（%s のもの）を引き継がない"
                                 % (row["段"], old["ブランチ"], old["リポジトリ"]))
                continue
            took = []
            # worktree は series-init の持ち分なので、引き継がずに下書きの値（空を含む）を書く。
            # ブランチ・PR は register の持ち分なので、古い写しでの上書きを止める
            for col in ("ブランチ", "PR"):
                if not row[col]:
                    if old[col]:
                        row[col] = old[col]
                        took.append(col)
                elif old[col] and old[col] != row[col]:
                    conflicts.append("段 %s の %s が今の値（%s）と違う: %s"
                                     % (row["段"], col, old[col], row[col]))
            if took:
                inherited.append("%s（%s）" % (row["段"], "・".join(took)))
        for old in cur.stages:
            if draft.stage(old["段"]) is not None or not old["PR"]:
                continue
            ref = "%s %s#%s" % (old["段"], old["リポジトリ"], old["PR"])
            if old["段"] in drop:
                dropped.append(ref)
            else:
                conflicts.append("下書きに無い段に PR が登録済み: " + ref)
        # 下書きの check は引き継ぐ前の表に当たるので、引き継いだ後の表でもう一度見る
        conflicts.extend(duplicate_prs(draft.stages))
        if conflicts:
            for c in conflicts:
                print("conflict: " + c)
            return 3
        text = replace_stage_table(draft.text, draft.stages)
        for name in ("進捗", "メモ"):
            body = section_lines(cur.text, name)
            if body is None:
                continue
            if section_span(split_lines(text), name) is not None:
                text = replace_section(text, name, body)
            else:
                # ## メモ は人の任意の節なので、下書きに無くても今の内容を残す
                # （## 進捗 は check が下書きにも求めるので、ここには来ない）
                text = text.rstrip("\n") + "\n\n## " + name + "\n" + "\n".join(body)
        # timestamp は status の持ち分で、引き継いだ ## 進捗 の取得時刻と対になる
        if cur.fm.get("timestamp"):
            text = set_frontmatter(text, "timestamp", cur.fm["timestamp"])
        atomic_write(args.series, text)
    print("written: " + args.series)
    for item in inherited:
        print("inherited: " + item)
    for item in reset:
        print("reset: " + item)
    for item in dropped:
        print("dropped: " + item)
    return 0


# ---------------------------------------------------------------- GitHub

def gh(args):
    proc = subprocess.run(["gh"] + args, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=False)
    if proc.returncode != 0:
        # plan の理由は 1 行 1 件で出すので、複数行の stderr を 1 行にまとめる
        err = " ".join(proc.stderr.decode("utf-8", "replace").split())
        raise RuntimeError("gh %s: %s" % (" ".join(args[:3]), err))
    try:
        return json.loads(proc.stdout.decode("utf-8"))
    except ValueError:
        raise RuntimeError("gh %s: JSON でない応答" % " ".join(args[:3]))


def get_pull(repo, number):
    return gh(["api", "repos/%s/pulls/%s" % (repo, number)])


GRAPHQL = ("query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r)"
           "{pullRequest(number:$n){state isDraft mergedAt headRefName"
           " baseRefName reviewDecision reviewThreads(first:100)"
           "{totalCount nodes{isResolved}}}}}")


def pull_state(pull):
    if pull.get("merged_at"):
        return "merged"
    if pull.get("state") == "closed":
        return "closed"
    return "draft" if pull.get("draft") else "open"


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def cmd_status(args):
    series = load(args.series)
    if series.errors:
        for e in series.errors:
            print("error: " + e)
        return 1
    rows = []
    warnings = []
    try:
        for s in series.stages:
            if not s["PR"]:
                rows.append([s["段"], s["リポジトリ"], "—", "未作成", "—", "—",
                             s["ブランチ"] or "—"])
                if s["ブランチ"]:
                    found = gh(["pr", "list", "-R", s["リポジトリ"], "--head",
                                s["ブランチ"], "--state", "all", "--json", "number"])
                    for p in found:
                        warnings.append("段 %s のブランチ %s に未登録の PR %s#%s がある"
                                        % (s["段"], s["ブランチ"], s["リポジトリ"],
                                           p["number"]))
                continue
            owner, name = s["リポジトリ"].split("/", 1)
            data = gh(["api", "graphql", "-f", "query=" + GRAPHQL,
                       "-f", "o=" + owner, "-f", "r=" + name, "-F", "n=" + s["PR"]])
            try:
                pr = data["data"]["repository"]["pullRequest"]
                pr["state"]
            except (KeyError, TypeError):
                raise RuntimeError("%s#%s の PR を読めない" % (s["リポジトリ"], s["PR"]))
            if pr["state"] == "MERGED":
                state = "merged（%s）" % (pr.get("mergedAt") or "")[:10]
            elif pr["state"] == "CLOSED":
                state = "closed"
            else:
                state = "draft" if pr.get("isDraft") else "open"
            threads = pr.get("reviewThreads") or {}
            unresolved = len([n for n in threads.get("nodes", [])
                              if not n.get("isResolved")])
            # 取るのは先頭の 100 件だけなので、それを超えたら下限であることを示す
            count = str(unresolved)
            if threads.get("totalCount", 0) > len(threads.get("nodes", [])):
                count += "+"
            rows.append([s["段"], s["リポジトリ"], "#" + s["PR"], state,
                         pr.get("reviewDecision") or "—", count,
                         pr.get("headRefName") or "—"])
            if s["ブランチ"] and pr.get("headRefName") != s["ブランチ"]:
                warnings.append("段 %s のブランチ列（%s）と PR のブランチ（%s）が違う"
                                % (s["段"], s["ブランチ"], pr.get("headRefName")))
        prefixes = [p.strip() for p in series.fm.get("branch_prefix", "").split(",")
                    if p.strip()]
        repos = []
        for s in series.stages:
            if s["リポジトリ"] not in repos:
                repos.append(s["リポジトリ"])
        for repo in repos:
            known = set(s["PR"] for s in series.stages
                        if s["リポジトリ"] == repo and s["PR"])
            for prefix in prefixes:
                found = gh(["pr", "list", "-R", repo, "--search", "head:" + prefix,
                            "--state", "all", "--json", "number,headRefName",
                            "--limit", str(PR_LIST_LIMIT)])
                if len(found) >= PR_LIST_LIMIT:
                    warnings.append("%s の %s の PR が %d 件以上あり、それ以降は調べていない"
                                    % (repo, prefix, PR_LIST_LIMIT))
                for p in found:
                    # head: の検索は前方一致より広く当たるので、接頭辞で絞り直す
                    if not p.get("headRefName", "").startswith(prefix):
                        continue
                    if str(p["number"]) in known:
                        continue
                    warnings.append("段に未登録の PR: %s#%s（ブランチ %s）"
                                    % (repo, p["number"], p["headRefName"]))
    except RuntimeError as e:
        print("error: GitHub の読み取りに失敗: %s" % e)
        return 1
    stamp = now_iso()
    table = [PROGRESS_HEADER,
             "|----|-----------|----|------|----------|----------------|---------|"]
    table += [format_row(r) for r in rows]
    body = ["", "<!-- series-sync status が GitHub から実測して書き換える。"
                "手で編集しない -->", "", "取得: " + stamp, ""] + table + [""]
    with Lock(args.series):
        text = read_text(args.series)
        if section_span(split_lines(text), "進捗") is None:
            print("error: ## 進捗 の節が無い")
            return 1
        text = replace_section(text, "進捗", body)
        text = set_frontmatter(text, "timestamp", stamp)
        atomic_write(args.series, text)
    print("取得: " + stamp)
    for line in table:
        print(line)
    for w in warnings:
        print("warning: " + w)
    return 0


def sha256(text):
    return hashlib.sha256((text or "").encode("utf-8")).hexdigest()


def make_dir(base):
    path = base
    n = 2
    while True:
        try:
            os.makedirs(path)
            return path
        except FileExistsError:
            path = "%s-%d" % (base, n)
            n += 1


def file_key(repo, number):
    return "%s__%s" % (repo.replace("/", "__"), number)


def write_file(path, text):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def cmd_plan(args):
    series = load(args.series)
    errors = check(series)
    if errors:
        for e in errors:
            print("error: " + e)
        return 1
    # dir: の行は常に絶対パスにする。相対のまま出すと、cwd の変わった次の apply で解決できない。
    # 既定の DIR は生ログの置き場 _runs/ の下（tmp/ の文書と分ける）
    if args.out:
        base = os.path.abspath(args.out.rstrip("/"))
    else:
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        base = os.path.join(os.path.dirname(os.path.abspath(args.series)),
                            "_runs", "series-sync", stamp)
    out = make_dir(base)
    items = []
    changes = 0
    errs = 0
    for s in series.stages:
        if not s["PR"]:
            continue
        repo, number = s["リポジトリ"], s["PR"]
        key = file_key(repo, number)
        item = {"stage": s["段"], "repo": repo, "number": int(number),
                "state": "", "action": "", "reason": "",
                "before_sha256": "", "before": None, "after": None}
        try:
            pull = get_pull(repo, number)
        except RuntimeError as e:
            item.update(action="error", reason="gh: %s" % e)
            items.append(item)
            errs += 1
            continue
        before = pull.get("body") or ""
        item["state"] = pull_state(pull)
        item["before_sha256"] = sha256(before)
        item["before"] = key + ".before.md"
        write_file(os.path.join(out, item["before"]), before)
        try:
            after, action = apply_block(before, render_block(series, s["段"]),
                                        args.migrate)
        except BodyError as e:
            item.update(action="error", reason=str(e))
            items.append(item)
            errs += 1
            continue
        item["after"] = key + ".after.md"
        write_file(os.path.join(out, item["after"]), after)
        item["action"] = "none" if after == before else action
        if item["action"] != "none":
            changes += 1
        items.append(item)
    with open(os.path.join(out, "plan.json"), "w", encoding="utf-8") as f:
        json.dump({"series": os.path.abspath(args.series), "items": items}, f,
                  ensure_ascii=False, indent=2)
    for it in items:
        line = "%s#%s %s %s" % (it["repo"], it["number"], it["state"] or "-",
                                it["action"])
        if it["reason"]:
            line += " " + it["reason"]
        print(line)
    print("changes: %d / errors: %d" % (changes, errs))
    print("dir: " + out)
    return 1 if errs else 0


def cmd_apply(args):
    # --plan は DIR と DIR/plan.json のどちらでも受ける。正規化は入口の 1 回だけにし、
    # 以降の参照（plan.json・after・patch.json）はすべて正規化した DIR を使う
    plan_dir = os.path.abspath(args.plan)
    if os.path.basename(plan_dir) == "plan.json":
        plan_dir = os.path.dirname(plan_dir)
    args.plan = plan_dir
    if not os.path.exists(os.path.join(args.plan, "plan.json")):
        print("error: plan.json が無い: " + args.plan)
        return 1
    with open(os.path.join(args.plan, "plan.json"), encoding="utf-8") as f:
        plan = json.load(f)
    items = plan["items"]
    refs = ["%s#%s" % (it["repo"], it["number"]) for it in items]
    for ref in args.only or []:
        if ref not in refs:
            print("error: plan に無い PR: " + ref)
            return 1
    bad = 0
    for it in items:
        ref = "%s#%s" % (it["repo"], it["number"])
        if args.only and ref not in args.only:
            continue
        if it["action"] not in ("insert", "replace", "migrate"):
            continue
        with open(os.path.join(args.plan, os.path.basename(it["after"])),
                  encoding="utf-8", newline="") as f:
            after = f.read()
        try:
            current = get_pull(it["repo"], it["number"]).get("body") or ""
            # やり直しの apply で、書き終えた PR を二重に書かず skipped にもしないため、
            # sha より先に after と比べる
            if current == after:
                print("unchanged: %s 本文がすでに after と同じ" % ref)
                continue
            if sha256(current) != it["before_sha256"]:
                print("skipped: %s 本文が plan の後に変わった" % ref)
                bad += 1
                continue
            patch = os.path.join(args.plan, file_key(it["repo"], it["number"])
                                 + ".patch.json")
            with open(patch, "w", encoding="utf-8") as f:
                json.dump({"body": after}, f, ensure_ascii=False)
            gh(["api", "-X", "PATCH", "repos/%s/pulls/%s" % (it["repo"], it["number"]),
                "--input", patch])
            reread = get_pull(it["repo"], it["number"]).get("body") or ""
        except RuntimeError as e:
            print("failed: %s %s" % (ref, e))
            bad += 1
            continue
        if reread != after:
            print("mismatch: %s 書き込み後の本文が一致しない" % ref)
            bad += 1
            continue
        print("written: " + ref)
    return 1 if bad else 0


def cmd_check(args):
    errors = check(load(args.series))
    for e in errors:
        print("error: " + e)
    return 1 if errors else 0


def cmd_render(args):
    series = load(args.series)
    errors = check(series)
    if errors:
        for e in errors:
            print("error: " + e)
        return 1
    if series.stage(args.stage) is None:
        print("error: 段が無い: " + args.stage)
        return 1
    block = render_block(series, args.stage)
    if not args.body_file:
        sys.stdout.write(block + "\n")
        return 0
    with open(args.body_file, encoding="utf-8", newline="") as f:
        body = f.read()
    try:
        result, _ = apply_block(body, block, args.migrate)
    except BodyError as e:
        print("error: " + str(e))
        return 1
    sys.stdout.buffer.write(result.encode("utf-8"))
    return 0


def main(argv):
    p = argparse.ArgumentParser(prog="series_sync.py")
    sub = p.add_subparsers(dest="cmd")
    sub.required = True
    c = sub.add_parser("check")
    c.add_argument("series")
    c = sub.add_parser("render")
    c.add_argument("series")
    c.add_argument("--stage", required=True)
    c.add_argument("--body-file")
    c.add_argument("--migrate", action="store_true")
    c = sub.add_parser("register")
    c.add_argument("series")
    c.add_argument("--repo", required=True)
    c.add_argument("--branch", required=True)
    c.add_argument("--pr", required=True, type=int)
    c.add_argument("--stage")
    c.add_argument("--worktree")
    c = sub.add_parser("write")
    c.add_argument("series")
    c.add_argument("--from", dest="from_", required=True)
    c.add_argument("--drop", action="append")
    c = sub.add_parser("status")
    c.add_argument("series")
    c = sub.add_parser("plan")
    c.add_argument("series")
    c.add_argument("--out")
    c.add_argument("--migrate", action="store_true")
    c = sub.add_parser("apply")
    c.add_argument("--plan", required=True)
    c.add_argument("--only", action="append")
    args = p.parse_args(argv)
    for path in (getattr(args, "series", None), getattr(args, "from_", None),
                 getattr(args, "body_file", None)):
        # write の series.md は初回に無いのが正常なので、series と --from だけを見る
        if path and not os.path.exists(path) and not (
                args.cmd == "write" and path == args.series):
            print("error: ファイルが無い: " + path)
            return 1
    handler = {"check": cmd_check, "render": cmd_render, "register": cmd_register,
               "write": cmd_write, "status": cmd_status, "plan": cmd_plan,
               "apply": cmd_apply}[args.cmd]
    return handler(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
