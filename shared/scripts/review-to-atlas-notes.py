#!/usr/bin/env python3
"""/review の tmp/review/unified.md の指摘を、atlas.nvim の Notes（atlas-notes add）にする。

使い方:
  python3 ~/.claude/scripts/review-to-atlas-notes.py --pr <PR の URL か番号>
      [--report tmp/review/unified.md] [--atlas-notes <path>] [--dry-run]

PR の head を checkout した worktree で実行する。行番号は HEAD のコミットのものとして付けるので、
HEAD が PR の head と違う・レポートが別の PR のもの・レポートがその後のコミットより古いときは止める。

終了コード: 0 = 1 件以上を追加した、追加するものがすべて既にあった、または --dry-run
            1 = 書き込めなかった（理由は stderr）。2 = 引数の誤り

標準ライブラリだけで、python 3.9 で動く書き方にする（/usr/bin/python3 で動かす経路があるため）。
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys

TYPES = {"C": "issue", "M": "suggestion", "I": "note", "H": "note"}

HEADING = re.compile(r"^### ([CMI]-\d+)\. (.+?)\s*$")
H_ITEM = re.compile(r"^- \*\*(H-\d+)\. (.+?)\*\* — `([^`]+)`\s*$")
FILE_LINE = re.compile(r"^\*\*ファイル\*\*: `([^`]+)`")
META = re.compile(r"^\*\*(エージェント|ファイル|確信度)\*\*")
PR_HEADER = re.compile(r"^\*\*PR #(\d+)\*\*")
LINE_REF = re.compile(r"^(.+?):L(\d+)(?:-L?(\d+))?$")


def fail(message):
    sys.stderr.write("review-to-atlas-notes: " + message + "\n")
    sys.exit(1)


def run(args, **kwargs):
    return subprocess.run(args, check=False, capture_output=True, text=True, **kwargs)


def fmt_time(epoch):
    return datetime.datetime.fromtimestamp(epoch).strftime("%Y-%m-%d %H:%M:%S")


def is_block_end(line):
    return line.startswith("#") or line.strip() == "---"


def first_paragraph(lines):
    """メタデータ行と空行を飛ばした後の、最初の段落（コードブロック・見出し・区切りの前まで）"""
    i = 0
    while i < len(lines) and (META.match(lines[i]) or not lines[i].strip()):
        i += 1
    para = []
    while i < len(lines):
        line = lines[i]
        if not line.strip() or line.startswith("```") or is_block_end(line):
            break
        para.append(line.strip())
        i += 1
    return "\n".join(para)


def parse(text):
    """指摘の一覧を返す。各要素は dict(id, title, ref, detail)"""
    lines = text.splitlines()
    items = []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = HEADING.match(line)
        if m:
            j = i + 1
            while j < len(lines) and not is_block_end(lines[j]):
                j += 1
            block = lines[i + 1 : j]
            ref = None
            for b in block:
                fm = FILE_LINE.match(b)
                if fm:
                    ref = fm.group(1)
                    break
            items.append({"id": m.group(1), "title": m.group(2), "ref": ref, "detail": first_paragraph(block)})
            i = j
            continue
        m = H_ITEM.match(line)
        if m:
            detail = ""
            if i + 1 < len(lines) and lines[i + 1].startswith("  ") and lines[i + 1].strip():
                detail = lines[i + 1].strip()
            items.append({"id": m.group(1), "title": m.group(2), "ref": m.group(3), "detail": detail})
        i += 1
    return items


def locate(ref):
    """`path:Ln` / `path:Ln-m` を (path, start, end) にする。使えなければ (None, 理由)"""
    m = LINE_REF.match(ref or "")
    if not m:
        return None, "行番号が無い"
    path = m.group(1)
    # atlas-notes は絶対パスと .. を拒否する。途中で失敗させず、ここで落とす
    if os.path.isabs(path) or ".." in path.split("/"):
        return None, "repo 相対のパスでない"
    start = int(m.group(2))
    end = int(m.group(3)) if m.group(3) else start
    if end < start:
        return None, "行の範囲が逆"
    return (path, start, end), None


def default_atlas_notes():
    data = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
    # note の保存先は Neovim の stdpath("data") で決まる。試行用の NVIM_APPNAME で開く note は、
    # 同じ NVIM_APPNAME の atlas-notes で書かないと見えない
    app = os.environ.get("NVIM_APPNAME") or "nvim"
    return os.path.join(data, app, "lazy", "atlas.nvim", "bin", "atlas-notes")


def main():
    ap = argparse.ArgumentParser(description="/review の指摘を atlas.nvim の Notes にする")
    ap.add_argument("--pr", required=True, help="PR の URL か番号")
    ap.add_argument("--report", default="tmp/review/unified.md", help="既定: repo の root からの tmp/review/unified.md")
    ap.add_argument("--atlas-notes", dest="atlas_notes", help="atlas-notes のパス（既定: atlas.nvim の bin/）")
    ap.add_argument("--dry-run", action="store_true", help="追加の予定を出すだけで書き込まない")
    args = ap.parse_args()

    res = run(["gh", "pr", "view", args.pr, "--json", "number,url,headRefOid"])
    if res.returncode != 0:
        fail("gh pr view が失敗しました:\n" + res.stderr.rstrip())
    try:
        pr = json.loads(res.stdout)
        number, url, head_oid = int(pr["number"]), pr["url"], pr["headRefOid"]
    except (ValueError, KeyError, TypeError):
        fail("gh pr view の出力を読めません: " + res.stdout.strip()[:200])

    res = run(["git", "rev-parse", "--show-toplevel", "HEAD"])
    if res.returncode != 0:
        fail("git の repo の中で実行してください:\n" + res.stderr.rstrip())
    # root はパスに空白を含みうるので、行で分ける
    root, head = res.stdout.splitlines()[:2]
    if head != head_oid:
        fail(
            "HEAD が PR の head と違います（行番号がずれるため止めます）\n"
            "  HEAD:          %s\n  PR の head:    %s\n"
            "  gh pr checkout %d するか、PR の worktree で実行してください" % (head, head_oid, number)
        )

    report = args.report if os.path.isabs(args.report) else os.path.join(root, args.report)
    try:
        with open(report, encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        fail("レポートを読めません: %s (%s)" % (report, e.strerror))

    header = None
    for line in text.splitlines():
        m = PR_HEADER.match(line)
        if m:
            header = int(m.group(1))
            break
    if header is None:
        fail(
            "レポートに PR 番号（**PR #N**）がありません。/review を PR に対して回したレポートを渡してください: "
            + report
        )
    if header != number:
        fail("レポートは PR #%d のもので、--pr の PR #%d と違います: %s" % (header, number, report))

    commit_time = int(run(["git", "log", "-1", "--format=%ct", "HEAD"]).stdout.strip() or "0")
    report_time = os.stat(report).st_mtime
    if report_time < commit_time:
        fail(
            "レポートが HEAD のコミットより古いです（レビューの後にコミットした印。/review を回し直してください）\n"
            "  レポート:          %s\n  HEAD のコミット:   %s" % (fmt_time(report_time), fmt_time(commit_time))
        )

    items = parse(text)
    if not items:
        fail("指摘を 0 件しか解析できませんでした（レポートの書式が変わった可能性があります）: " + report)

    planned, skipped = [], []
    for it in items:
        loc, why = locate(it["ref"])
        if loc is None:
            skipped.append((it, why))
            continue
        body = "[%s] %s" % (it["id"], it["title"])
        if it["detail"]:
            body += "\n\n" + it["detail"]
        planned.append(
            {"id": it["id"], "type": TYPES[it["id"][0]], "file": loc[0], "start": loc[1], "end": loc[2], "body": body}
        )

    notes_cmd = args.atlas_notes or default_atlas_notes()
    if not (os.path.isfile(notes_cmd) and os.access(notes_cmd, os.X_OK)):
        fail("atlas-notes が見つかりません（atlas.nvim が入っているか、--atlas-notes で渡してください）: " + notes_cmd)

    res = run([notes_cmd, "list", "--target", url])
    if res.returncode != 0:
        fail("atlas-notes list が失敗しました:\n" + res.stderr.rstrip())
    try:
        existing = json.loads(res.stdout)["notes"]
        # commit も鍵に含める: atlas は note の commit から PR の head までの差分で表示位置を写すので、
        # 別のコミットの同じ行番号は別の位置を指す
        seen = {(n["file_path"], n["commit"], int(n["start_line"]), int(n["end_line"]), n["body"]) for n in existing}
    except (ValueError, KeyError, TypeError):
        fail("atlas-notes list の出力を読めません: " + res.stdout.strip()[:200])

    added = duplicate = 0
    for p in planned:
        if (p["file"], head, p["start"], p["end"], p["body"]) in seen:
            duplicate += 1
            continue
        where = "%s:%d-%d" % (p["file"], p["start"], p["end"])
        if args.dry_run:
            print("would add: [%s] %s (%s)" % (p["id"], where, p["type"]))
            continue
        res = run(
            [
                notes_cmd,
                "add",
                "--target",
                url,
                "--commit",
                head,
                "--file",
                p["file"],
                "--start-line",
                str(p["start"]),
                "--end-line",
                str(p["end"]),
                "--type",
                p["type"],
                "--body",
                p["body"],
            ]
        )
        if res.returncode != 0:
            print("added %d, skipped (no line) %d, skipped (duplicate) %d" % (added, len(skipped), duplicate))
            fail("atlas-notes add が [%s] %s で失敗しました:\n%s" % (p["id"], where, res.stderr.rstrip()))
        added += 1

    print("added %d, skipped (no line) %d, skipped (duplicate) %d" % (added, len(skipped), duplicate))
    for it, why in skipped:
        print("skipped: %s %s — %s" % (it["id"], it["ref"] or "（参照なし）", why))
    if args.dry_run:
        return 0
    if added == 0 and duplicate == 0:
        fail("追加できる指摘がありませんでした（すべて行番号が無いか、repo 相対のパスでない）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
