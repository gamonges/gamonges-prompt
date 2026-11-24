#!/usr/bin/env python3
# release-video の台本の検証・承認・段の状態（validate / table / approve / status / session / begin / mark / rebuild）。
# 編集したら: bash shared/scripts/tests/test-release-video.sh
# exit: 0=成功 / 1=入力やデータの誤り（stderr に 1 行）/ 2=引数の誤り / 3=外部コマンドの失敗
import argparse
import datetime
import json
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rv_common as rv  # noqa: E402


def _add_common(p):
    p.add_argument("--dir", default=None, help="作業ディレクトリ（既定 ./tmp/release-video）")
    p.add_argument("--profile", default=None, help="設定ファイル")


def cmd_validate(args):
    ctx = rv.load_ctx(args.dir, args.profile)
    n_video = len([s for s in ctx.scenes if s["kind"] != "omit"])
    print("OK: シーン %d 件（動画に入るもの %d 件）" % (len(ctx.scenes), n_video))
    return 0


def _read_script(ctx):
    p = os.path.join(ctx.dir, "script.md")
    if not os.path.exists(p):
        raise rv.RvError("script.md が無い（reference/script-format.md の雛形から作る）")
    with open(p, encoding="utf-8") as f:
        return p, f.read()


def _approved_sha(ctx):
    a = rv.read_manifest(os.path.join(ctx.dir, "approved.json"))
    return a.get("sha") if a else None


def cmd_table(args):
    ctx = rv.load_ctx(args.dir, args.profile)
    path, text = _read_script(ctx)
    parts = rv.split_table(text)
    if parts is None:
        raise rv.RvError("script.md に印 %s と %s が 1 組だけ無い" % (rv.TABLE_BEGIN, rv.TABLE_END))
    new = parts[0] + "\n" + rv.table_text(ctx) + "\n" + parts[2]
    if _approved_sha(ctx) != rv.scenes_sha(ctx):
        new = rv.set_status(new, "draft")
    if new != text:
        rv.atomic_write(path, new)
    print("table: script.md の表を更新した" if new != text else "table: 変更なし")
    return 0


def cmd_approve(args):
    ctx = rv.load_ctx(args.dir, args.profile)
    path, text = _read_script(ctx)
    if not rv.table_matches(ctx):
        raise rv.RvError("script.md の表が scenes.json と違う。先に table を流す")
    sha = rv.scenes_sha(ctx)
    today = datetime.date.today().isoformat()
    rv.write_manifest(os.path.join(ctx.dir, "approved.json"), {"sha": sha, "date": today})
    rv.atomic_write(path, rv.set_status(text, "stable"))
    print("approve: 承認した（%s）" % sha[:8])
    return 0


def cmd_status(args):
    states = rv.stage_states(rv.workdir(args.dir), args.profile)
    for st, r in states:
        line = "%s: %s" % (st, r["state"])
        if r["msg"]:
            line += " — " + r["msg"]
        print(line)
    print("next: %s" % rv.next_stage(states))
    return 0


def _target(ctx, stage, sid):
    sc = next((s for s in ctx.scenes if s["id"] == sid), None)
    if sc is None:
        raise rv.RvError("id '%s' が scenes.json に無い" % sid)
    if sc["kind"] not in rv.STAGE_KINDS[stage] or sc["kind"] == "omit":
        raise rv.RvError("id '%s' の kind が %s で、%s の段の対象でない" % (sid, sc["kind"], stage))
    return sc


def _material(ctx, stage, sc):
    name = rv.clip_name(sc["id"]) if stage == "record" else rv.card_name(sc["id"])
    return name, os.path.join(ctx.dir, rv.STAGE_DIRS[stage], name)


SESSION_STALE = "ブラウザに登録した overlay が今の設定と違う。撮影用の session を開き直す（ログインし直しになる。recording.md）"


def cmd_session(args):
    # overlay は読み込んだ時点の設定を取り込み、2 回目の登録では初期化しない（先に登録した古い方が勝つ）。
    # だから登録する中身をここで確かめて印を残し、begin が印と今の期待値を照合する
    ctx = rv.load_ctx(args.dir, args.profile, need_scenes=False)
    bad = rv.source_mismatch(ctx, "record", None)
    if bad:
        raise rv.RvError(bad)
    p = os.path.join(ctx.dir, "overlay.js")
    rv.write_manifest(rv.session_path(ctx), {"overlay": rv.file_sha(p)})
    print(json.dumps(p, ensure_ascii=True))
    return 0


def cmd_begin(args):
    # 素材は skill の外（ブラウザ）で作られるので、作る直前の入力を控え、mark でその控えと照合する。
    # 出どころを確かめないと、古い設定の素材が新しい設定の sha で done になる
    ctx = rv.load_ctx(args.dir, args.profile)
    stage = args.stage
    sc = _target(ctx, stage, args.id)
    bad = rv.source_mismatch(ctx, stage, sc)
    if bad:
        raise rv.RvError(bad)
    if stage == "record":
        mark_ = rv.read_manifest(rv.session_path(ctx)) or {}
        if mark_.get("overlay") != rv.file_sha(os.path.join(ctx.dir, "overlay.js")):
            raise rv.RvError(SESSION_STALE)
    _, path = _material(ctx, stage, sc)
    olds = [path]
    if stage == "record":
        olds.append(os.path.join(ctx.dir, "clips", sc["id"] + ".events"))
    for p in olds:
        if os.path.exists(p):
            os.unlink(p)
    rv.write_manifest(rv.meta_path(ctx, stage, sc["id"]), {"input": rv.input_sha(ctx, stage, sc)})
    print("begin: %s %s の素材を作ってよい（古い素材を消した）" % (stage, sc["id"]))
    return 0


def cmd_mark(args):
    ctx = rv.load_ctx(args.dir, args.profile)
    stage = args.stage
    sc = _target(ctx, stage, args.id)
    name, path = _material(ctx, stage, sc)
    # 検査の順序は固定する（最初に当たった 1 行で止める）
    if not os.path.isfile(path):
        raise rv.RvError("素材が無い: %s" % path)
    mpath_meta = rv.meta_path(ctx, stage, sc["id"])
    meta = rv.read_manifest(mpath_meta)
    if meta is None:
        raise rv.RvError("begin を通していない素材: %s（scenes.py begin から作り直す）" % name)
    sha = rv.input_sha(ctx, stage, sc)
    if meta.get("input") != sha:
        raise rv.RvError("素材を作った後に入力が変わった: %s。begin から作り直す" % name)
    bad = rv.source_mismatch(ctx, stage, sc)
    if bad:
        raise rv.RvError(bad)
    if os.path.getsize(path) == 0:
        raise rv.RvError("素材が 0 バイト: %s" % name)
    if stage == "cards":
        size = rv.png_size(path)
        if size is None:
            raise rv.RvError("PNG でない: %s" % name)
        if size != (1920, 1080):
            raise rv.RvError("大きさが %dx%d（1920x1080 でない）: %s" % (size[0], size[1], name))
    entry = {"sha": sha, "file": name, "content": rv.file_sha(path)}
    if stage == "record":
        entry["duration"] = rv.probe_duration(path)
    mpath = rv.manifest_path(ctx, stage)
    man = rv.read_manifest(mpath) or {}
    man[sc["id"]] = entry
    rv.write_manifest(mpath, man)
    # 控えを使い回すと、begin を通さない差し替えが通る
    os.unlink(mpath_meta)
    print("mark: %s %s を記録した" % (stage, sc["id"]))
    return 0


def _remove_tree(path):
    if os.path.isdir(path):
        shutil.rmtree(path, ignore_errors=True)


def cmd_rebuild(args):
    # 控えは作業ディレクトリ直下しか読まれないので、退避先へ移すと戻し忘れが見えなくなる。
    # だから戻していない行があれば止めるか、写し終えてから入れ替える（どの失敗でも控えは D の直下に残る）
    d = rv.workdir(args.dir)
    if not os.path.isdir(d):
        raise rv.RvError("作業ディレクトリが無い: %s" % d)
    dc = os.path.join(d, "data-changes.md")
    back = rv.parse_data_changes(dc)
    if back and not args.carry:
        raise rv.RvError("撮影用データを戻していない: %s。先に戻して控えを埋めるか、--carry で控えを新しい作業ディレクトリに引き継ぐ"
                         % "、".join(back))
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    bak, work = d + ".bak-" + stamp, d + ".new-" + stamp
    if os.path.exists(bak) or os.path.exists(work):
        raise rv.RvError("退避先か作業用が既にある: %s" % (bak if os.path.exists(bak) else work))
    carried = bool(back) and args.carry
    try:
        os.makedirs(work)
        if carried:
            shutil.copy2(dc, os.path.join(work, "data-changes.md"))
    except OSError as e:
        _remove_tree(work)
        raise rv.RvError("控えを写せない（%s）。何も動かしていない" % e)
    try:
        os.rename(d, bak)
    except OSError as e:
        _remove_tree(work)
        raise rv.RvError("作業ディレクトリを退避できない（%s）。何も動かしていない" % e)
    try:
        os.rename(work, d)
    except OSError as e:
        os.rename(bak, d)
        _remove_tree(work)
        raise rv.RvError("新しい作業ディレクトリに入れ替えられない（%s）。元に戻した" % e)
    print("rebuild: %s を %s へ退避した%s" % (d, bak, "（控えを引き継いだ）" if carried else ""))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="scenes.py", description="release-video の台本と段の状態")
    sub = ap.add_subparsers(dest="cmd")
    sub.required = True
    for name, fn in (("validate", cmd_validate), ("table", cmd_table), ("approve", cmd_approve),
                     ("status", cmd_status), ("session", cmd_session), ("begin", cmd_begin),
                     ("mark", cmd_mark), ("rebuild", cmd_rebuild)):
        p = sub.add_parser(name)
        _add_common(p)
        p.set_defaults(fn=fn)
        if name in ("begin", "mark"):
            p.add_argument("--stage", required=True, choices=["record", "cards"])
            p.add_argument("--id", required=True)
        if name == "rebuild":
            p.add_argument("--carry", action="store_true",
                           help="戻していない控えを新しい作業ディレクトリに引き継ぐ")
    args = ap.parse_args(argv)
    try:
        return args.fn(args)
    except rv.RvError as e:
        rv.die(e)
    except OSError as e:
        rv.die(rv.RvError("ファイルを読み書きできない（%s）" % e))


if __name__ == "__main__":
    sys.exit(main())
