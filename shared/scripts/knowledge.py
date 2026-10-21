#!/usr/bin/env python3
"""tmp/ の md の frontmatter を検査し、目録を作り、版を保存する。

書式は OKF v0.2（open-knowledge-format の SPEC.md）の部分集合で、説明の正本は
`knowledge.py spec`。判定の本体はここだけに置き、hook（hook-lint-skill-frontmatter.sh）は
書いた後と書く前の中身を作って `check` を呼ぶだけにする（必須キーの集合を 2 か所に持たない）。

/usr/bin/python3（3.9）でも動かすため、標準ライブラリだけを使い、match 文や
`X | None` の注釈を使わない。3.9 は約 1,000 バイトを超える日本語の行で偽の
Non-UTF-8 エラーを出すので、メッセージは短い行に分ける。
"""

import argparse
import datetime
import fnmatch
import os
import re
import shutil
import subprocess
import sys
import tempfile

REQUIRED = ["type", "title", "description", "status"]
STATUSES = ("draft", "stable", "deprecated")

# 種類の登録表。上から最初に一致した行を使うので、具体的な名前を glob より前に置く。
# glob は tmp/ からの相対パスに、/ で区切った要素ごとに当てる（* は / を跨がない）
TYPES = [
    ("Plan Review", "plan-review.md"),
    ("Fix Plan", "fix-plan.md"),
    ("Implementation Plan", "plan*.md"),
    ("Review Report", "review/*.md"),
    ("Context", "context.md"),
    ("Context", "handoff/*.md"),
    ("Research", "research.md"),
    ("Grill Session", "grill.md"),
    ("Business Scenario", "scenario.md"),
    ("Series", "series.md"),
    ("Series", "series.draft.md"),
    ("Strategic DDD Review", "strategic-ddd-review.md"),
    ("Strategic DDD", "strategic-ddd.md"),
    ("Outline", "outline.md"),
    ("Spec Check", "spec-check.md"),
    ("Coupling Precheck", "coupling-precheck.md"),
    ("Coupling Gate", "coupling-gate.md"),
    ("Coupling Audit", "coupling-audit.md"),
    ("Coupling Plan Diff", "coupling-plan-diff.md"),
    ("Integration Test Scenario", "integration-test-scenario.md"),
    ("Integration Test Results", "integration-test-results.md"),
    ("Comment Review", "comment-review.md"),
    ("Blog Draft", "blog-draft.md"),
    ("Step Result", "step-*-result.md"),
    ("Doc Sync Report", "doc-sync-report.md"),
    ("Fix Request", "fixes.md"),
    ("Feedback", "feedback.md"),
]

# tmp/ の直下の、生ログと画像の置き場。中の md は文書として扱わない
EXCLUDED_DIRS = ("_runs", "_assets")
# OKF の予約名（index.md・log.md）と、既存の lint が見る SKILL.md。どの階層でも外す
EXCLUDED_NAMES = ("index.md", "log.md", "skill.md")
# 複数行の値の書き出し（| と >、その修飾子つき）。この repo では使わない
BLOCK_SCALARS = ("|", ">")

TEMPLATE = """---
type: {type}
title: <題材>
description: <1 文の要約>
status: stable
---"""

SPEC = """tmp/ の md の frontmatter（OKF v0.2 の部分集合）

ファイルの先頭行の --- から次の --- までを frontmatter として読む。
値は平坦な `key: value` に限る（字下げ・| ・> の複数行は使わない）。

必須:
  type         種類。`knowledge.py types` の名前を使う（未知の値も許す）
  title        題材
  description  1 文の要約。tmp/index.md に載る
  status       draft | stable | deprecated
status: deprecated のとき:
  superseded_by  後継のパス（repo からの相対。例: tmp/plan.md）
任意:
  archived_reason  snapshot が書く旧版の理由
  timestamp        既存のキー（そのまま残す）
  そのほかのキーも残してよい

対象: repo 直下の tmp/ の md（.git のあるディレクトリの tmp/）。
対象外: tmp/_runs/・tmp/_assets/ の下、index.md・log.md・SKILL.md。
今ある frontmatter の無い文書への編集は問わない。frontmatter を持つ
文書の編集は、違反を増やさないものだけを通す。

例:
""" + TEMPLATE.format(type="Implementation Plan")


class UsageError(Exception):
    pass


def read_text(path):
    with open(path, "rb") as f:
        return f.read().decode("utf-8", "replace")


def frontmatter_lines(text):
    """先頭の frontmatter の行（--- の間）。frontmatter が無ければ None。

    閉じの --- が無いものも frontmatter なしとみなす（先頭の水平線と区別できないため）。
    """
    lines = text.split("\n")
    if not lines or lines[0].rstrip("\r").strip() != "---":
        return None
    for i in range(1, len(lines)):
        if lines[i].rstrip("\r").strip() == "---":
            return [l.rstrip("\r") for l in lines[1:i]]
    return None


def unquote(value):
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def parse(text):
    """(frontmatter の dict か None, 書式の違反の集合)。

    平坦な key: value だけを読む。字下げした行と複数行の値は、黙って別のキーとして
    読まずに unsupported-syntax にする（ネストを平坦なキーに誤読しないため）。
    """
    lines = frontmatter_lines(text)
    if lines is None:
        return None, set()
    fm = {}
    bad = set()
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line[0] in " \t" or ":" not in line:
            bad.add("unsupported-syntax")
            continue
        key, _, value = line.partition(":")
        value = value.strip()
        if value[:1] in BLOCK_SCALARS:
            bad.add("unsupported-syntax")
        fm[key.strip()] = unquote(value).strip()
    return fm, bad


def violations(text):
    """違反の種類の集合。missing:<key>・invalid:<key>・no-frontmatter・unsupported-syntax"""
    fm, bad = parse(text)
    if fm is None:
        return {"no-frontmatter"}
    v = set(bad)
    for key in REQUIRED:
        if not fm.get(key):
            v.add("missing:" + key)
    status = fm.get("status")
    if status and status not in STATUSES:
        v.add("invalid:status")
    if status == "deprecated" and not fm.get("superseded_by"):
        v.add("missing:superseded_by")
    return v


def split_tmp(path):
    """repo 直下の tmp/ の下なら (repo のパス, tmp/ からの相対の要素のリスト)、違えば None。

    tmp の親に .git（ファイルかディレクトリ）があるものだけを tmp/ とみなす。
    scratchpad（/private/tmp/...）や monorepo のパッケージの tmp/ は外れる。
    """
    parts = os.path.normpath(path).split(os.sep)
    for i in range(len(parts) - 1, 0, -1):
        if parts[i] != "tmp":
            continue
        root = os.sep.join(parts[:i]) or os.sep
        if os.path.exists(os.path.join(root, ".git")):
            return root, parts[i + 1:]
    return None


def is_document(rel):
    """tmp/ からの相対の要素のリストが、検査・目録の対象の md か。"""
    if not rel or not rel[-1].lower().endswith(".md"):
        return False
    if rel[0] in EXCLUDED_DIRS and len(rel) > 1:
        return False
    return rel[-1].lower() not in EXCLUDED_NAMES


def in_scope(path):
    hit = split_tmp(path)
    return hit is not None and is_document(hit[1])


def match_glob(rel, pattern):
    pat = pattern.split("/")
    return len(pat) == len(rel) and all(
        fnmatch.fnmatchcase(r, p) for r, p in zip(rel, pat))


def guess_type(rel):
    """tmp/ からの相対の要素のリストから種類を引く。引けなければ None。"""
    if ".archived-" in rel[-1]:
        return None
    for name, pattern in TYPES:
        if match_glob(rel, pattern):
            return name
    return None


def template_for(path):
    hit = split_tmp(path)
    name = guess_type(hit[1]) if hit else None
    return TEMPLATE.format(type=name or "<種類>")


def require_abs(name, value):
    if value is not None and not os.path.isabs(value):
        raise UsageError("%s は絶対パスで渡す: %s" % (name, value))


def report(head, kinds, path):
    print(head)
    if kinds:
        print("違反: " + ", ".join(sorted(kinds)))
    print("tmp/ の md には type・title・description・status が必須です。")
    print("書式: python3 ~/.claude/scripts/knowledge.py spec")
    print(template_for(path))


def cmd_check(args):
    require_abs("--path", args.path)
    require_abs("--old-path", args.old_path)
    # 対象外でも stdin を読み切る。読まずに終わると、パイプで大きな本文を渡す hook 側の
    # 書き手が SIGPIPE で落ち、pipefail の下で判定の失敗に見える
    new = sys.stdin.buffer.read().decode("utf-8", "replace")
    if not in_scope(args.path):
        return 0
    op = args.op
    # 対象外の場所から tmp/ に入る文書は、今ある tmp/ の文書ではないので免除しない
    if op == "edit" and args.old_path and not in_scope(args.old_path):
        op = "write"
    after = violations(new)
    if op == "write":
        if not after:
            return 0
        if after == {"no-frontmatter"}:
            report("frontmatter がありません。", None, args.path)
        else:
            report("frontmatter に問題があります。", after, args.path)
        return 1
    if args.old_file is None:
        raise UsageError("--op edit には --old-file が要る")
    try:
        before_text = read_text(args.old_file)
    except OSError as e:
        raise UsageError("--old-file を読めない: %s" % e)
    if parse(before_text)[0] is None:
        return 0
    added = after - violations(before_text)
    if not added:
        return 0
    report("この編集で frontmatter の違反が増えます。", added, args.path)
    return 1


INDEX_HEAD = ("自動生成。手で編集しない。"
              "再生成: `python3 ~/.claude/scripts/knowledge.py index`")
# 違反ではなく「キーの不足」に数える種類（install 前に作られた旧形式の文書）
LEGACY_KINDS = set("missing:" + k for k in REQUIRED)


def resolve_tmp(value):
    """--tmp の値か、省略時は git の toplevel の下の tmp/。"""
    if value:
        tmp = os.path.abspath(value)
    else:
        try:
            top = subprocess.run(
                ["git", "rev-parse", "--show-toplevel"],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                universal_newlines=True, check=True).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            raise UsageError("git の repo の外では --tmp を渡す")
        tmp = os.path.join(top, "tmp")
    if not os.path.isdir(tmp):
        raise UsageError("tmp/ のディレクトリが無い: %s" % tmp)
    return tmp


def documents(tmp):
    """tmp/ の下の文書の相対パス（/ 区切り）を辞書順で。"""
    found = []
    for dirpath, dirnames, filenames in os.walk(tmp):
        if dirpath == tmp:
            dirnames[:] = [d for d in dirnames if d not in EXCLUDED_DIRS]
        dirnames.sort()
        base = os.path.relpath(dirpath, tmp)
        for name in filenames:
            rel = name if base == "." else os.path.join(base, name)
            if is_document(rel.split(os.sep)):
                found.append(rel.replace(os.sep, "/"))
    return sorted(found)


def successor_exists(tmp, value):
    """superseded_by の指す先（ファイルかディレクトリ）が在るか。相対なら repo から。"""
    if os.path.isabs(value):
        return os.path.exists(value)
    return os.path.exists(os.path.join(os.path.dirname(tmp), value))


def classify(tmp, rel):
    """(区分, frontmatter の dict か None, 違反の集合)。区分は bad・legacy・none・ok。"""
    text = read_text(os.path.join(tmp, rel))
    fm, _ = parse(text)
    if fm is None:
        return "none", None, set()
    v = violations(text)
    sb = fm.get("superseded_by")
    if sb and not successor_exists(tmp, sb):
        v.add("invalid:superseded_by")
    if not v:
        return "ok", fm, v
    if v <= LEGACY_KINDS:
        return "legacy", fm, v
    return "bad", fm, v


def survey(tmp):
    rows = []
    for rel in documents(tmp):
        kind, fm, v = classify(tmp, rel)
        rows.append((rel, kind, fm or {}, v))
    return rows


def cmd_lint(args):
    tmp = resolve_tmp(args.tmp)
    rows = survey(tmp)
    sections = [("bad", "違反"), ("legacy", "キーの不足"),
                ("none", "frontmatter なし"), ("ok", "正常")]
    for kind, label in sections:
        hits = [r for r in rows if r[1] == kind]
        print("%s: %d" % (label, len(hits)))
        for rel, _, _, v in hits:
            print("  " + rel + (": " + ", ".join(sorted(v)) if v else ""))
    return 1 if any(r[1] == "bad" for r in rows) else 0


def link(text, rel):
    text = text.replace("\\", "\\\\").replace("[", "\\[").replace("]", "\\]")
    return "* [%s](%s)" % (text, rel)


def render_index(rows):
    out = [INDEX_HEAD, "", "# tmp/ の目録"]
    ok = [r for r in rows if r[1] == "ok"]
    for name in sorted(set(r[2]["type"] for r in ok)):
        out += ["", "## " + name]
        cur = [r for r in ok if r[2]["type"] == name
               and r[2]["status"] != "deprecated"]
        old = [r for r in ok if r[2]["type"] == name
               and r[2]["status"] == "deprecated"]
        for label, group in (("現行", cur), ("旧版（deprecated）", old)):
            if not group:
                continue
            out += ["", "### " + label, ""]
            for rel, _, fm, _ in group:
                mark = "（draft）" if fm["status"] == "draft" else ""
                out.append("%s - %s%s" % (link(fm["title"], rel),
                                          fm["description"], mark))
    tail = [("legacy", "キーの不足"), ("none", "frontmatter なし"),
            ("bad", "違反")]
    for kind, label in tail:
        hits = [r for r in rows if r[1] == kind]
        if not hits:
            continue
        out += ["", "## " + label, ""]
        for rel, _, fm, v in hits:
            line = link(fm.get("title") or rel, rel)
            if v:
                line += " - " + ", ".join(sorted(v))
            out.append(line)
    return "\n".join(out) + "\n"


def write_index(tmp):
    """tmp/index.md を書き直す。自分の生成物でない index.md は上書きしない。"""
    path = os.path.join(tmp, "index.md")
    text = render_index(survey(tmp))
    if os.path.exists(path):
        current = read_text(path)
        if current.split("\n", 1)[0] != INDEX_HEAD:
            raise UsageError("自動生成でない index.md は上書きしない: %s" % path)
        if current == text:
            return path
    # 途中で止まっても壊れた index.md を残さない（同じ dir の一時ファイルから置き換える）
    # 接尾辞を .md にしない（残ったときに文書として目録に載らないように）
    fd, part = tempfile.mkstemp(prefix=".index.", suffix=".tmp", dir=tmp)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        # mkstemp は 0600 で作る。ほかの生成物と同じく umask に従わせる
        mask = os.umask(0)
        os.umask(mask)
        os.chmod(part, 0o666 & ~mask)
        os.replace(part, path)
    except BaseException:
        if os.path.exists(part):
            os.unlink(part)
        raise
    return path


def cmd_index(args):
    tmp = resolve_tmp(args.tmp)
    # --stdout は書かずに出す（読み取り専用の /status が使う）
    if args.stdout:
        sys.stdout.write(render_index(survey(tmp)))
    else:
        print(write_index(tmp))
    return 0


REASON_MAX = 40
# 種類を引けない写しの type（lint の「キーの不足」に落とさないため、空にしない）
FALLBACK_TYPE = "Document"


def normalize_reason(reason):
    r = re.sub(r"[\s/]+", "-", reason.strip()).strip("-")[:REASON_MAX]
    if not r:
        raise UsageError("--reason が空（/ と空白を - に変えた後）")
    return r


def first_heading(text):
    lines = text.split("\n")
    fm = frontmatter_lines(text)
    start = len(fm) + 2 if fm is not None else 0
    for line in lines[start:]:
        if line.startswith("# "):
            return line[2:].strip()
    return None


def set_keys(text, updates):
    """先頭の frontmatter の updates（キー → 値）を置き換えるか足す。無ければ作る。"""
    lines = text.split("\n")
    fm = frontmatter_lines(text)
    if fm is None:
        block = ["---"] + ["%s: %s" % kv for kv in updates] + ["---"]
        return "\n".join(block) + "\n" + text
    end = len(fm) + 1
    keys = dict(updates)
    for i in range(1, end):
        key = lines[i].partition(":")[0]
        if lines[i][:1] not in " \t" and key.strip() in keys:
            lines[i] = "%s: %s" % (key.strip(), keys.pop(key.strip()))
    extra = ["%s: %s" % (k, v) for k, v in updates if k in keys]
    return "\n".join(lines[:end] + extra + lines[end:])


def archive_md(path, rel, successor, reason, when):
    """写しの md を旧版に書き換える。元の mtime を写しにも残す（いつの版かが分かるように）。"""
    stat = os.stat(path)
    text = read_text(path)
    fm, _ = parse(text)
    fm = fm or {}
    updates = []
    if not fm.get("type"):
        updates.append(("type", guess_type(rel) or FALLBACK_TYPE))
    if not fm.get("title"):
        updates.append(("title", first_heading(text) or rel[-1]))
    if not fm.get("description"):
        updates.append(("description", "%s の %s の版" % (successor, when)))
    updates += [("status", "deprecated"), ("superseded_by", successor),
                ("archived_reason", reason)]
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(set_keys(text, updates))
    os.utime(path, (stat.st_atime, stat.st_mtime))


def reserve(dest, is_dir):
    """dest を排他的に作る。在れば -2・-3 … を付ける（並んで回っても上書きしない）。"""
    stem, ext = (dest, "") if is_dir else os.path.splitext(dest)
    n = 1
    while True:
        cand = stem + ("" if n == 1 else "-%d" % n) + ext
        try:
            if is_dir:
                os.mkdir(cand)
            else:
                os.close(os.open(cand, os.O_CREAT | os.O_EXCL | os.O_WRONLY))
            return cand
        except FileExistsError:
            n += 1


def repo_relative(path):
    """repo 直下の tmp/ の下なら repo からの相対（/ 区切り）、違えば絶対パス。"""
    hit = split_tmp(os.path.abspath(path))
    if hit is None:
        return os.path.abspath(path)
    return "/".join(["tmp"] + hit[1])


def snapshot_one(src, reason, note, stamp, when):
    src = src.rstrip("/") or src
    is_dir = os.path.isdir(src)
    head, name = os.path.split(src)
    stem, ext = (name, "") if is_dir else os.path.splitext(name)
    dest = reserve(os.path.join(head, "%s.archived-%s-%s%s" % (stem, stamp, reason, ext)),
                   is_dir)
    successor = repo_relative(src) + ("/" if is_dir else "")
    # 種類と title の既定は元の場所（tmp/review/x.md）で引く。写しの名前は .archived- を含み、引けない
    hit = split_tmp(os.path.abspath(src))
    src_rel = hit[1] if hit else [name]
    if not is_dir:
        shutil.copy2(src, dest)
        if dest.lower().endswith(".md"):
            archive_md(dest, src_rel, successor, note, when)
        return dest
    shutil.copytree(src, dest, dirs_exist_ok=True)
    for dirpath, _, filenames in os.walk(dest):
        for f in sorted(filenames):
            if f.lower().endswith(".md"):
                sub = os.path.relpath(os.path.join(dirpath, f), dest).split(os.sep)
                archive_md(os.path.join(dirpath, f), src_rel + sub, successor, note, when)
    return dest + "/"


def cmd_snapshot(args):
    reason = normalize_reason(args.reason)
    # 名前には正規化した理由、archived_reason には元の文（frontmatter は 1 行に限るので改行だけ外す）
    note = " ".join(args.reason.split())
    for p in args.paths:
        if not os.path.exists(p):
            raise UsageError("退避するパスが無い: %s" % p)
    now = datetime.datetime.now()
    stamp = now.strftime("%Y%m%d-%H%M")
    when = now.strftime("%Y-%m-%d %H:%M")
    tmps = []
    for p in args.paths:
        print(snapshot_one(p, reason, note, stamp, when))
        hit = split_tmp(os.path.abspath(p))
        if hit and os.path.join(hit[0], "tmp") not in tmps:
            tmps.append(os.path.join(hit[0], "tmp"))
    # 写しはできているので、目録の失敗では止めない（呼び出し側が「旧版を保存できなかった」と取り違えないように）
    for tmp in tmps:
        try:
            write_index(tmp)
        except (UsageError, OSError) as e:
            sys.stderr.write("warning: 目録を更新できなかった: %s\n" % e)
    return 0


def cmd_types(args):
    for name, pattern in TYPES:
        print("%s\ttmp/%s" % (name, pattern))
    return 0


def cmd_spec(args):
    print(SPEC)
    return 0


class Parser(argparse.ArgumentParser):
    """引数の誤りを exit 2 の error: 行にそろえる（argparse の既定も 2 だが文言を固定する）。"""

    def error(self, message):
        sys.stderr.write("error: %s\n" % message)
        sys.exit(2)


def build_parser():
    p = Parser(prog="knowledge.py", description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", parser_class=Parser)
    sub.required = True
    c = sub.add_parser("check", help="書いた後の中身（stdin）を検査する")
    c.add_argument("--path", required=True)
    c.add_argument("--op", required=True, choices=["write", "edit"])
    c.add_argument("--old-file")
    c.add_argument("--old-path")
    c.set_defaults(func=cmd_check)
    for name, func, text in (("lint", cmd_lint, "tmp/ の md を 4 区分で一覧する"),
                             ("index", cmd_index, "tmp/index.md を書き直す")):
        x = sub.add_parser(name, help=text)
        x.add_argument("--tmp", help="既定は git の toplevel の下の tmp/")
        x.set_defaults(func=func)
        if name == "index":
            x.add_argument("--stdout", action="store_true",
                           help="index.md を書かずに目録を標準出力に出す")
    n = sub.add_parser("snapshot", help="旧版を .archived-<日時>-<理由> の写しとして残す")
    n.add_argument("paths", nargs="+", metavar="PATH")
    n.add_argument("--reason", required=True)
    n.set_defaults(func=cmd_snapshot)
    t = sub.add_parser("types", help="種類の登録表を表示する")
    t.set_defaults(func=cmd_types)
    s = sub.add_parser("spec", help="frontmatter の書式を表示する")
    s.set_defaults(func=cmd_spec)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except UsageError as e:
        sys.stderr.write("error: %s\n" % e)
        return 2
    except OSError as e:
        # traceback の exit 1 は lint の「違反あり」と区別できないので、内部エラーの 2 にそろえる
        sys.stderr.write("error: %s\n" % e)
        return 2


if __name__ == "__main__":
    sys.exit(main())
