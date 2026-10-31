#!/usr/bin/env python3
"""/review の tmp/review/unified.md の指摘を、atlas.nvim の Notes（atlas-notes add）にする。

使い方:
  python3 ~/.claude/scripts/review-to-atlas-notes.py --pr <PR の URL か番号>
      [--report tmp/review/unified.md] [--atlas-notes <path>] [--dry-run]

PR の head を checkout した worktree で実行する。行番号は HEAD のコミットのものとして付けるので、
HEAD が PR の head と違う・レポートが別の PR のもの・レポートのヘッダの SHA（**HEAD**）が無いか HEAD と違うときは止める。

終了コード: 0 = 1 件以上を追加した、追加するものがすべて既にあった、または --dry-run
            1 = 書き込めなかった（理由は stderr）。2 = 引数の誤り。130 = Ctrl-C で中断した

標準ライブラリだけで、python 3.9 で動く書き方にする（/usr/bin/python3 で動かす経路があるため）。
"""

import argparse
import json
import os
import re
import subprocess
import sys

TYPES = {"C": "issue", "M": "suggestion", "I": "note", "H": "note"}

HEADING = re.compile(r"^### ([CMI]-\d+)\. (.+?)\s*$", re.ASCII)
H_ITEM = re.compile(r"^- \*\*(H-\d+)\. (.+?)\*\* — (.+?)\s*$", re.ASCII)
FILE_LINE = re.compile(r"^\*\*ファイル\*\*: (.+?)\s*$")
REFS = re.compile(r"`([^`]+)`")
# HEADING・H_ITEM に合わないのに項目らしい行。読み飛ばすと件数にも一覧にも出ずに消えるので、skip に積んで見せる
LOOKS_LIKE_ITEM = re.compile(r"^(### [CMIH]|- \*\*H)\s*[-‐－―–]?\s*\d")
META = re.compile(r"^\*\*(エージェント|ファイル|確信度)\*\*")
PR_HEADER = re.compile(r"^\*\*PR #(\d+)\*\*", re.ASCII)
HEAD_HEADER = re.compile(r"^\*\*HEAD\*\*: `([0-9a-f]{40})`\s*$", re.ASCII)
LINE_REF = re.compile(r"^(.+?):L(\d+)(?:-L?(\d+))?$", re.ASCII)
# LINE_REF に合わないが行番号を書こうとした形（列挙・全角コロン・en dash の範囲）
LINE_LIKE = re.compile(r"[:：]L\d|L\d+[,–]")


def fail(message):
    sys.stderr.write("review-to-atlas-notes: " + message + "\n")
    sys.exit(1)


def run(args, **kwargs):
    # 非 UTF-8 の出力は置き換え文字で読む（壊れた note が 1 件あるだけで毎回落ちないように）。その note の body は
    # 保存値と一致せず、重複判定に合わずに再追加されうるが、毎回落ちるより軽い
    try:
        return subprocess.run(
            args, check=False, capture_output=True, encoding="utf-8", errors="replace", timeout=60, **kwargs
        )
    except FileNotFoundError:
        fail("%s が見つかりません" % args[0])
    except subprocess.TimeoutExpired:
        fail("%s が 60 秒で終わりませんでした" % " ".join(args[:2]))


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


def pick_refs(text):
    """行の中の backtick の参照から (位置に使う参照, 残りの参照) を返す。

    位置は行番号の付いた最初の参照。どれにも行番号が無ければ最初の参照を返し、locate に理由を判定させる
    """
    refs = REFS.findall(text)
    if not refs:
        return None, []
    k = next((n for n, r in enumerate(refs) if LINE_REF.match(r)), 0)
    return refs[k], refs[:k] + refs[k + 1 :]


def parse(text):
    """(指摘の一覧, 解釈できなかった行の一覧) を返す。指摘は dict(id, title, ref, related, detail)"""
    lines = text.splitlines()
    items, unparsed = [], []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = HEADING.match(line)
        if m:
            j = i + 1
            while j < len(lines) and not is_block_end(lines[j]):
                j += 1
            block = lines[i + 1 : j]
            ref, related = None, []
            for b in block:
                fm = FILE_LINE.match(b)
                if fm:
                    ref, related = pick_refs(fm.group(1))
                    break
            items.append(
                {"id": m.group(1), "title": m.group(2), "ref": ref, "related": related, "detail": first_paragraph(block)}
            )
            i = j
            continue
        m = H_ITEM.match(line)
        if m:
            ref, related = pick_refs(m.group(3))
            detail = []
            j = i + 1
            while j < len(lines) and lines[j].startswith("  ") and lines[j].strip():
                detail.append(lines[j].strip())
                j += 1
            items.append({"id": m.group(1), "title": m.group(2), "ref": ref, "related": related, "detail": "\n".join(detail)})
            i = j
            continue
        if LOOKS_LIKE_ITEM.match(line):
            unparsed.append(line[:60])
        i += 1
    return items, unparsed


def locate(ref, head_lines):
    """`path:Ln` / `path:Ln-m` を (path, start, end) にする。使えなければ (None, 理由)

    head_lines(path) は HEAD のそのファイルの行数（無ければ None）
    """
    m = LINE_REF.match(ref or "")
    if not m:
        if LINE_LIKE.search(ref or ""):
            return None, "行番号の書式を解釈できない"
        return None, "行番号が無い"
    # atlas-notes は保存時に先頭の ./ を外し \ を / にする。同じ形にしないと重複判定の鍵が一致せず、
    # 再実行のたびに note が増える
    path = m.group(1).replace("\\", "/")
    while path.startswith("./"):
        path = path[2:]
    # atlas-notes は絶対パスと .. を拒否する。途中で失敗させず、ここで落とす
    if os.path.isabs(path) or ".." in path.split("/"):
        return None, "repo 相対のパスでない"
    start = int(m.group(2))
    end = int(m.group(3)) if m.group(3) else start
    if start < 1:
        return None, "行番号が 1 未満"
    if end < start:
        return None, "行の範囲が逆"
    lines = head_lines(path)
    if lines is None:
        return None, "HEAD にファイルが無い"
    if end > lines:
        return None, "行がファイルの範囲外"
    return (path, start, end), None


def head_line_counter(root):
    """HEAD のファイルの行数を返す関数（無い・blob でなければ None）。同じパスは 1 回だけ git を呼ぶ"""
    cache = {}

    def count(path):
        if path not in cache:
            # cat-file blob はディレクトリ（tree）を拒否する。git show はディレクトリの一覧を rc 0 で返す
            res = run(["git", "-C", root, "cat-file", "blob", "HEAD:" + path])
            cache[path] = None if res.returncode != 0 else len(res.stdout.splitlines())
        return cache[path]

    return count


UNPARSED = "書式を解釈できない"


def print_summary(added, skipped, duplicate):
    """件数の行と skip の内訳。成功・add の失敗・中断のどれでも同じものを出す"""
    unparsed = sum(1 for _, why in skipped if why == UNPARSED)
    print(
        "added %d, skipped (no line) %d, skipped (unparsed) %d, skipped (duplicate) %d"
        % (added, len(skipped) - unparsed, unparsed, duplicate)
    )
    for it, why in skipped:
        print("skipped: %s %s — %s" % (it["id"], it["ref"] or "（参照なし）", why))


def default_atlas_notes():
    data = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
    # note の保存先は Neovim の stdpath("data") で決まる。試行用の NVIM_APPNAME で開く note は、
    # 同じ NVIM_APPNAME の atlas-notes で書かないと見えない
    app = os.environ.get("NVIM_APPNAME") or "nvim"
    return os.path.join(data, app, "lazy", "atlas.nvim", "bin", "atlas-notes")


def main():
    ap = argparse.ArgumentParser(description="/review の指摘を atlas.nvim の Notes にする")
    ap.add_argument("--pr", required=True, help="PR の URL か番号")
    ap.add_argument("--report", help="レポートのパス（相対パスは cwd から。既定: repo の root の tmp/review/unified.md）")
    ap.add_argument("--atlas-notes", dest="atlas_notes", help="atlas-notes のパス（既定: atlas.nvim の bin/）")
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="追加の予定を出すだけで書き込まない（重複判定のため、atlas-notes の list は実行する）",
    )
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

    report = os.path.abspath(args.report) if args.report else os.path.join(root, "tmp", "review", "unified.md")
    try:
        with open(report, encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        fail("レポートを読めません: %s (%s)" % (report, e.strerror))

    header = reviewed = None
    for line in text.splitlines():
        m = PR_HEADER.match(line)
        if m and header is None:
            header = int(m.group(1))
        m = HEAD_HEADER.match(line)
        if m and reviewed is None:
            reviewed = m.group(1)
        if header is not None and reviewed is not None:
            break
    if header is None:
        fail(
            "レポートに PR 番号（**PR #N**）がありません。/review を PR に対して回したレポートを渡してください: "
            + report
        )
    if header != number:
        fail("レポートは PR #%d のもので、--pr の PR #%d と違います: %s" % (header, number, report))

    # 鮮度は mtime ではなく、レビューした SHA で判定する。mtime は同じ秒のコミットやコピーで新しくなり、
    # 古い行番号の note が別のコードに付く。SHA が HEAD（= PR の head）と一致するときだけ、行番号は今のコードのもの
    if reviewed is None:
        fail(
            "レポートにレビュー対象の HEAD の SHA がありません（**HEAD**: `<40 桁>`）。"
            "/review を回し直してください: " + report
        )
    if reviewed != head:
        fail(
            "レポートは別のコミットのレビューです（行番号がずれるため止めます。/review を回し直してください）\n"
            "  レポートの SHA:  %s\n  HEAD:            %s" % (reviewed, head)
        )

    items, unparsed = parse(text)
    if not items and not unparsed:
        fail("指摘を 0 件しか解析できませんでした（レポートの書式が変わった可能性があります）: " + report)

    planned, skipped = [], []
    head_lines = head_line_counter(root)
    for it in items:
        loc, why = locate(it["ref"], head_lines)
        if loc is None:
            skipped.append((it, why))
            continue
        body = "[%s] %s" % (it["id"], it["title"])
        if it["detail"]:
            body += "\n\n" + it["detail"]
        if it["related"]:
            body += "\n\n関連: " + ", ".join(it["related"])
        planned.append(
            {"id": it["id"], "type": TYPES[it["id"][0]], "file": loc[0], "start": loc[1], "end": loc[2], "body": body}
        )
    for line in unparsed:
        skipped.append(({"id": "?", "ref": line}, UNPARSED))

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
    try:
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
                print_summary(added, skipped, duplicate)
                fail("atlas-notes add が [%s] %s で失敗しました:\n%s" % (p["id"], where, res.stderr.rstrip()))
            added += 1
    except KeyboardInterrupt:
        # 追加済みの分は残る。再実行すれば重複判定で続きから書けるので、どこまで書いたかを出して止める
        print_summary(added, skipped, duplicate)
        sys.stderr.write("review-to-atlas-notes: 中断しました（再実行すれば続きから追加します）\n")
        return 130

    print_summary(added, skipped, duplicate)
    if args.dry_run:
        return 0
    if added == 0 and duplicate == 0:
        fail("追加できる指摘がありませんでした（理由は上の skipped の行）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
