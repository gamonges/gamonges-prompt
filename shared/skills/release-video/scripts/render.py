#!/usr/bin/env python3
# release-video のカード（cards/<id>.html）と重ね表示（overlay.js）を作る。
# 編集したら: bash shared/scripts/tests/test-release-video.sh
# exit: 0=成功 / 1=入力やデータの誤り / 2=引数の誤り / 3=外部コマンドの失敗
import argparse
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rv_common as rv  # noqa: E402


def cmd_card(args):
    ctx = rv.load_ctx(args.dir, args.profile)
    cards = [s for s in ctx.scenes if s["kind"] == "card"]
    credit = rv.credit_of(ctx)
    required = bool(ctx.voice and ctx.voice.get("terms", {}).get("credit_required"))
    if required and credit and not cards:
        raise rv.RvError("クレジットが要るのに kind: card のシーンが無く、載せる場所が無い")
    outdir = os.path.join(ctx.dir, "cards")
    for sc in cards:
        rv.atomic_write(os.path.join(outdir, sc["id"] + ".html"), rv.card_html(ctx, sc))
    print("card: %d 枚の html を作った（%s）。begin の後に png に撮り、確かめてから mark する" % (len(cards), outdir))
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
    note = check_patterns(ctx.eff["blur_patterns"])
    rv.atomic_write(os.path.join(ctx.dir, "overlay.js"), rv.overlay_text(ctx))
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
