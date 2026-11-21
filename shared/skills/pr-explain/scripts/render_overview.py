#!/usr/bin/env python3
"""pr-explain の図解（overview.html）を、データの JSON と雛形から作る。

使い方:
    python3 render_overview.py --data <data.json> --out <overview.html> [--template <雛形>]

データを検証してから、雛形の <script type="application/json" id="data"> の本文だけを差し替える。
検証で落ちたら、何が悪いかを 1 行 stderr に出して exit 1（出力は作らない・既存の出力に触れない）。
引数の誤りは exit 2。

HTML パーサーは JSON の文字列の中でも `</script>` で script 要素を閉じ、`<!--` で解析の状態を
変える。描画時の esc() は解析の後に動くので防げない。そのため埋め込みの時点で `<`・`>`・`&` と
U+2028・U+2029 を JSON の Unicode エスケープ（バックスラッシュ・u・4 桁）に置き換える。
JSON の文字列の中では元の文字に戻るので、描画側の JSON.parse の結果は変わらない。

/usr/bin/python3（3.9）でも動く書き方にする。
"""

import argparse
import json
import os
import sys
import tempfile

OPEN = '<script type="application/json" id="data">'
CLOSE = "</script>"
DEFAULT_TEMPLATE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "reference", "overview-template.html")

NODE_KINDS = ("new", "mod", "ext")
FILE_KINDS = ("new", "mod", "ext", "gen")

# ソースにバックスラッシュのエスケープ列を書かない（エディタやツールが書き出し時に解釈して、
# 置換先が置換元と同じ文字になる事故を避ける）。置換先は chr(92) から組み立てる
BS = chr(92)
ESCAPES = [
    ("&", BS + "u0026"),  # 先に & を置き換える（後の置換で入る文字に & は無いが、順序を固定する）
    ("<", BS + "u003c"),
    (">", BS + "u003e"),
    (chr(0x2028), BS + "u2028"),
    (chr(0x2029), BS + "u2029"),
]


class DataError(Exception):
    pass


def is_int(v):
    # bool は int の派生なので除く（True を 1 として通さない）
    return isinstance(v, int) and not isinstance(v, bool)


def need(obj, key, where, typ):
    if not isinstance(obj, dict) or key not in obj:
        raise DataError("%s が無い" % (where + key if where else key))
    v = obj[key]
    if not isinstance(v, typ):
        raise DataError("%s の型が違う（%s が要る）" % (where + key, typ.__name__ if isinstance(typ, type) else "/".join(t.__name__ for t in typ)))
    return v


def check_kind(v, allowed, where):
    if v not in allowed:
        raise DataError("%s が許可外（%r。許すのは %s）" % (where, v, " / ".join(allowed)))


def validate(d):
    if not isinstance(d, dict):
        raise DataError("データの最上位がオブジェクトでない")
    for k in ("title", "meta"):
        need(d, k, "", str)
    for k in ("purpose", "method", "flow", "pins", "files"):
        need(d, k, "", list)
    g = need(d, "graph", "", dict)
    cols = need(g, "columns", "graph.", list)
    nodes = need(g, "nodes", "graph.", list)
    edges = need(g, "edges", "graph.", list)
    if not cols:
        # 描画は最後の列の座標から幅を出すので、列が無いと幅が NaN になる
        raise DataError("graph.columns が空（1 列以上が要る）")
    for i, c in enumerate(d["purpose"]):
        need(c, "title", "purpose[%d]." % i, str)
        need(c, "body", "purpose[%d]." % i, str)
    for i, c in enumerate(d["method"]):
        w = "method[%d]." % i
        check_kind(need(c, "kind", w, str), NODE_KINDS, w + "kind")
        need(c, "title", w, str)
        need(c, "body", w, str)
    for i, s in enumerate(d["flow"]):
        if not isinstance(s, str):
            raise DataError("flow[%d] が文字列でない" % i)
    ids = set()
    for i, n in enumerate(nodes):
        w = "graph.nodes[%d]." % i
        nid = need(n, "id", w, str)
        if nid in ids:
            raise DataError("%sid が重複（%r）" % (w, nid))
        ids.add(nid)
        col = n.get("col") if isinstance(n, dict) else None
        if not is_int(col) or not 0 <= col < len(cols):
            raise DataError("%scol が範囲外（%r。0〜%d）" % (w, col, len(cols) - 1))
        need(n, "label", w, str)
        if "note" in n and not isinstance(n["note"], str):
            raise DataError("%snote が文字列でない" % w)
        check_kind(need(n, "kind", w, str), NODE_KINDS, w + "kind")
        if "pin" in n:
            p = n["pin"]
            ok = is_int(p) or (isinstance(p, list) and p and all(is_int(x) for x in p))
            if not ok:
                raise DataError("%spin が整数か整数の配列でない（%r）" % (w, p))
    for i, e in enumerate(edges):
        w = "graph.edges[%d]" % i
        if not isinstance(e, list) or len(e) not in (2, 3) or not all(isinstance(x, str) for x in e):
            raise DataError("%s が [元, 先] か [元, 先, ラベル] の文字列の配列でない" % w)
        for x in e[:2]:
            if x not in ids:
                raise DataError("%s の id %r が graph.nodes に無い" % (w, x))
    for i, p in enumerate(d["pins"]):
        w = "pins[%d]." % i
        if not isinstance(p, dict) or not is_int(p.get("n")):
            raise DataError("%sn が整数でない" % w)
        need(p, "where", w, str)
        need(p, "question", w, str)
    for i, f in enumerate(d["files"]):
        w = "files[%d]." % i
        check_kind(need(f, "kind", w, str), FILE_KINDS, w + "kind")
        need(f, "name", w, str)
        need(f, "what", w, str)
        a = f.get("added") if isinstance(f, dict) else None
        if not is_int(a) or a < 0:
            raise DataError("%sadded が非負の整数でない（%r）" % (w, a))


def embed(d):
    s = json.dumps(d, ensure_ascii=False, indent=2)
    for src, dst in ESCAPES:
        s = s.replace(src, dst)
    return s


def render(template_text, d):
    if template_text.count(OPEN) != 1:
        raise DataError("雛形の data の目印（%s）が 1 つでない（%d 個）" % (OPEN, template_text.count(OPEN)))
    i = template_text.index(OPEN) + len(OPEN)
    j = template_text.find(CLOSE, i)
    if j < 0:
        raise DataError("雛形の data の script 要素が閉じていない")
    return template_text[:i] + "\n" + embed(d) + "\n" + template_text[j:]


def main(argv=None):
    ap = argparse.ArgumentParser(description="pr-explain の図解をデータの JSON と雛形から作る")
    ap.add_argument("--data", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--template", default=DEFAULT_TEMPLATE)
    a = ap.parse_args(argv)
    try:
        try:
            with open(a.data, encoding="utf-8") as f:
                d = json.load(f)
        except ValueError as e:
            raise DataError("データの JSON の構文エラー（%s）" % e)
        validate(d)
        with open(a.template, encoding="utf-8") as f:
            html = render(f.read(), d)
    except DataError as e:
        sys.stderr.write("error: %s\n" % e)
        return 1
    except OSError as e:
        sys.stderr.write("error: 読めない（%s）\n" % e)
        return 1
    # 書き終えてから置き換える（途中で落ちても既存の出力を壊さない）
    out_dir = os.path.dirname(os.path.abspath(a.out))
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=out_dir, prefix=".overview-", suffix=".html")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(html)
        os.replace(tmp, a.out)
    except OSError as e:
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        sys.stderr.write("error: 書けない（%s）\n" % e)
        return 1
    print(a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
