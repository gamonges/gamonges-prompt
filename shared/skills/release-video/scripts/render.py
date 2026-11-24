#!/usr/bin/env python3
# release-video のカード（cards/<id>.html）と重ね表示（overlay.js）を作る。
# 編集したら: bash shared/scripts/tests/test-release-video.sh
# exit: 0=成功 / 1=入力やデータの誤り / 2=引数の誤り / 3=外部コマンドの失敗
import argparse
import html
import json
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rv_common as rv  # noqa: E402

REF = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "reference")


def _read_ref(name):
    with open(os.path.join(REF, name), encoding="utf-8") as f:
        return f.read()


def esc(s):
    return html.escape(s, quote=True)


def emph(s):
    """エスケープの後に **…** だけを <b> にする（ほかの文字はタグにならない）。"""
    return re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", esc(s))


def css_vars(brand):
    c = brand["colors"]
    return (":root{--bg-from:%s;--bg-to:%s;--text:%s;--accent:%s;--emphasis:%s;--muted:%s;--font:%s}" % (
        c["bg_from"], c["bg_to"], c["text"], c["accent"], c["emphasis"], c["muted"],
        brand["font_family"]))


def card_html(ctx, scene, credit_here, template):
    card = scene["card"]
    parts = []
    if card.get("kicker"):
        parts.append('<div class="k">%s</div>' % esc(card["kicker"]))
    parts.append('<div class="m">%s</div>' % "<br>".join(emph(x) for x in card["lines"]))
    if card.get("sub"):
        parts.append('<div class="s">%s</div>' % esc(card["sub"]))
    logo = ctx.eff["brand"]["logo_text"]
    if logo:
        parts.append('<div class="logo">%s</div>' % esc(logo))
    if credit_here:
        parts.append('<div class="credit">%s</div>' % esc(rv.credit_of(ctx)))
    out = template.replace("/*VARS*/", css_vars(ctx.eff["brand"]))
    return out.replace("<!--CARD-->", "".join(parts))


def cmd_card(args):
    ctx = rv.load_ctx(args.dir, args.profile)
    cards = [s for s in ctx.scenes if s["kind"] == "card"]
    credit = rv.credit_of(ctx)
    required = bool(ctx.voice and ctx.voice.get("terms", {}).get("credit_required"))
    if required and credit and not cards:
        raise rv.RvError("クレジットが要るのに kind: card のシーンが無く、載せる場所が無い")
    template = _read_ref("card-template.html")
    last = rv.last_card_id(ctx)
    outdir = os.path.join(ctx.dir, "cards")
    for sc in cards:
        text = card_html(ctx, sc, bool(credit) and sc["id"] == last, template)
        rv.atomic_write(os.path.join(outdir, sc["id"] + ".html"), text)
    print("card: %d 枚の html を作った（%s）。png に撮って確かめた後に mark する" % (len(cards), outdir))
    return 0


def _node_ok():
    if not shutil.which("node"):
        return False
    try:
        r = subprocess.run(["node", "--version"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError:
        return False
    return r.returncode == 0


def check_patterns(patterns):
    for p in patterns:
        try:
            re.compile(p)
        except re.error as e:
            raise rv.RvError("blur_patterns: 式 %r が python で通らない（%s）" % (p, e))
    if not patterns:
        return "ぼかしの式なし"
    if not _node_ok():
        return "JS での検証を省略（node が無い）"
    prog = "for (const p of process.argv.slice(1)) new RegExp(p, 'i')"
    r = subprocess.run(["node", "-e", prog, "--"] + list(patterns),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    if r.returncode != 0:
        first = ((r.stderr or "").strip().splitlines() or ["不明"])[-1]
        raise rv.RvError("blur_patterns: JS の RegExp で通らない式がある（%s）" % first)
    return "JS でも検証した"


def cmd_overlay(args):
    ctx = rv.load_ctx(args.dir, args.profile, need_scenes=False)
    patterns = ctx.eff["blur_patterns"]
    note = check_patterns(patterns)
    colors = ctx.eff["brand"]["colors"]
    cfg = {"accent": colors["accent"], "emphasis": colors["emphasis"], "blur_patterns": patterns}
    # ensure_ascii で U+2028・U+2029 を含む非 ASCII を JSON のエスケープにする（JS の行区切りで壊れない）
    head = "window.__ovConfig = %s;\n" % json.dumps(cfg, ensure_ascii=True, sort_keys=True)
    rv.atomic_write(os.path.join(ctx.dir, "overlay.js"), head + _read_ref("overlay-template.js"))
    print("overlay: overlay.js を作った（%s）" % note)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="render.py", description="release-video のカードと重ね表示")
    sub = ap.add_subparsers(dest="cmd")
    sub.required = True
    for name, fn in (("card", cmd_card), ("overlay", cmd_overlay)):
        p = sub.add_parser(name)
        p.add_argument("--dir", default=None)
        p.add_argument("--profile", default=None)
        p.set_defaults(fn=fn)
    args = ap.parse_args(argv)
    try:
        return args.fn(args)
    except rv.RvError as e:
        rv.die(e)
    except OSError as e:
        rv.die(rv.RvError("ファイルを読み書きできない（%s）" % e))


if __name__ == "__main__":
    sys.exit(main())
