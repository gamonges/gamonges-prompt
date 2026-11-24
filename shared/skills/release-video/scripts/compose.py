#!/usr/bin/env python3
# release-video の合成: シーンごとの mp4（同じ形）を作って結合し、出力と build/manifest.json を書く。
# 編集したら: bash shared/scripts/tests/test-release-video.sh
# exit: 0=成功 / 1=入力やデータの誤り（前の段が揃っていない等）/ 2=引数の誤り / 3=外部コマンドの失敗
# 前の段（script・voice・record・cards）が done でなければ ffmpeg を 1 回も呼ばない。
import argparse
import os
import shlex
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rv_common as rv  # noqa: E402

PRE_STAGES = ("script", "voice", "record", "cards")
BASE = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error"]
OUT_OPTS = [
    "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-r", "30",
    "-video_track_timescale", "15360",
    "-c:a", "aac", "-ar", "48000", "-ac", "2", "-b:a", "192k",
]


def f3(x):
    return "%.3f" % x


def check_prerequisites(ctx):
    for st, r in rv.stage_states(ctx):
        if st in PRE_STAGES and r["state"] != "done":
            raise rv.RvError("前の段が揃っていない — %s: %s（%s）" % (st, r["state"], r["msg"]))


def audio_path(ctx, sid):
    ent = (rv.read_manifest(rv.manifest_path(ctx, "voice")) or {}).get(sid) or {}
    return os.path.join(ctx.dir, "audio", ent["file"])


def scene_command(ctx, sc, item, out):
    sid = sc["id"]
    d = ctx.dir
    length = item["length"]
    cmd = list(BASE)
    if sc["kind"] == "card":
        cmd += ["-loop", "1", "-framerate", "30", "-i", os.path.join(d, "cards", rv.card_name(sid))]
        vf = "scale=1920:1080,fps=30,format=yuv420p"
    else:
        cmd += ["-i", os.path.join(d, "clips", rv.clip_name(sid))]
        short = max(0.0, length - item["video"])
        vf = "tpad=stop_mode=clone:stop_duration=%s,scale=1920:1080,fps=30,format=yuv420p" % f3(short)
    if sc.get("narr"):
        cmd += ["-i", audio_path(ctx, sid)]
        af = "aresample=48000,apad"
    else:
        cmd += ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo"]
        af = "aresample=48000"
    cmd += ["-t", f3(length), "-vf", vf, "-af", af, "-map", "0:v:0", "-map", "1:a:0"]
    cmd += OUT_OPTS + [out]
    return cmd


def concat_text(paths):
    return "".join("file '%s'\n" % p.replace("'", "'\\''") for p in paths)


def run(cmd, what):
    try:
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as e:
        raise rv.fail_ext("ffmpeg を起動できない（%s）" % e)
    if r.returncode != 0:
        tail = (r.stderr or b"").decode("utf-8", "replace").strip().splitlines()
        raise rv.fail_ext("ffmpeg が失敗した（%s）%s" % (what, (": " + tail[-1]) if tail else ""))


def main(argv=None):
    ap = argparse.ArgumentParser(prog="compose.py", description="release-video の合成")
    ap.add_argument("--dir", default=None)
    ap.add_argument("--profile", default=None)
    ap.add_argument("--out", default=rv.DEFAULT_OUT, help="出力（作業ディレクトリからの相対）")
    ap.add_argument("--dry-run", action="store_true", help="ffmpeg の引数を表示だけする")
    args = ap.parse_args(argv)
    try:
        return compose(args)
    except rv.RvError as e:
        rv.die(e)
    except OSError as e:
        rv.die(rv.RvError("ファイルを読み書きできない（%s）" % e))


def compose(args):
    ctx = rv.load_ctx(args.dir, args.profile)
    check_prerequisites(ctx)
    items, total = rv.timeline(ctx)
    by_id = dict((s["id"], s) for s in ctx.scenes)
    build = os.path.join(ctx.dir, "build")
    outname = args.out
    outpath = os.path.join(ctx.dir, outname)
    part = os.path.join(build, "concat-part.mp4")
    scene_outs = [os.path.join(build, it["id"] + ".mp4") for it in items]
    cmds = [(it["id"], scene_command(ctx, by_id[it["id"]], it, o)) for it, o in zip(items, scene_outs)]
    concat_file = os.path.join(build, "concat.txt")
    final = BASE + ["-f", "concat", "-safe", "0", "-i", concat_file, "-c", "copy", part]
    if args.dry_run:
        for sid, c in cmds:
            print("# シーン %s" % sid)
            print(" ".join(shlex.quote(x) for x in c))
        print("# concat.txt")
        sys.stdout.write(concat_text(scene_outs))
        print("# 結合")
        print(" ".join(shlex.quote(x) for x in final))
        return 0
    if not shutil.which("ffmpeg"):
        raise rv.fail_ext("ffmpeg が PATH に無い（導入の案内は recording.md）")
    os.makedirs(build, exist_ok=True)
    for sid, c in cmds:
        run(c, "シーン %s" % sid)
    rv.atomic_write(concat_file, concat_text(scene_outs))
    try:
        run(final, "結合")
        os.replace(part, outpath)
    finally:
        if os.path.exists(part):
            os.unlink(part)
    dur = rv.probe_duration(outpath)
    over = dur > ctx.max_seconds
    rv.write_manifest(os.path.join(build, "manifest.json"), {
        "sha": rv.compose_sha(ctx, outname), "file": outname,
        "content": rv.file_sha(outpath), "duration": dur, "over": over,
    })
    print("compose: %s（%.1f 秒。時間割の合計 %.1f 秒）" % (outpath, dur, total))
    if over:
        print("over: %.1f" % (dur - ctx.max_seconds))
    return 0


if __name__ == "__main__":
    sys.exit(main())
