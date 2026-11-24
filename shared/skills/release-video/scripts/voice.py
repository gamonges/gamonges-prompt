#!/usr/bin/env python3
# release-video の声: 読み上げ文の整形・声の候補と規約の表示・試し読み・合成・尺の見積もり。
# 編集したら: bash shared/scripts/tests/test-release-video.sh
# exit: 0=成功 / 1=入力やデータの誤り / 2=引数の誤り / 3=外部コマンド・エンジンの失敗
# VOICEVOX への要求は loopback の host だけに、環境変数のプロキシを使わず、リダイレクトにも
# 追従せずに送る（ナレーションに未公開の情報が入るため。curl の確認 hook は urllib を見ない）。
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rv_common as rv  # noqa: E402

DEFAULT_ENGINE_URL = "http://127.0.0.1:50021"
LOOPBACK_HOSTS = ("127.0.0.1", "localhost", "::1")
TIMEOUT = 120
VOICE_KEYS = ("engine", "voice", "speaker", "speaker_uuid", "speed", "pause_scale", "credit", "terms")
TERMS_KEYS = ("source", "summary", "use", "credit_required", "confirmed_by_user", "confirmed_on")


# ------------------------------------------------------------------ HTTP（loopback・プロキシなし・リダイレクトなし）
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())


def check_engine_url(url):
    try:
        u = urllib.parse.urlparse(url)
        host = u.hostname
        u.port  # noqa: B018  不正な port はここで ValueError
    except ValueError:
        raise rv.RvError("--engine-url が URL として読めない: %s" % url, rv.EXIT_ARG)
    if u.scheme != "http" or host not in LOOPBACK_HOSTS or u.username or u.password:
        raise rv.RvError(
            "--engine-url は http の loopback（127.0.0.1・localhost・[::1]）だけを許す: %s" % url,
            rv.EXIT_ARG)
    return url.rstrip("/")


def http(method, base, path, data=None, headers=None):
    req = urllib.request.Request(base + path, data=data, method=method, headers=headers or {})
    try:
        with OPENER.open(req, timeout=TIMEOUT) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        if 300 <= e.code < 400:
            raise rv.fail_ext("エンジンがリダイレクト（%d）を返した。追従しない（%s）" % (e.code, base))
        raise rv.fail_ext("エンジンがエラーを返した（HTTP %d: %s%s）" % (e.code, base, path.split("?")[0]))
    except (urllib.error.URLError, OSError):
        raise rv.fail_ext("エンジンに接続できない（%s）" % base)


def get_json(base, path):
    try:
        return json.loads(http("GET", base, path).decode("utf-8"))
    except ValueError:
        raise rv.fail_ext("エンジンの応答が JSON でない（%s）" % path.split("?")[0])


# ------------------------------------------------------------------ voice.json の検査
def validate_voice(v):
    if not isinstance(v, dict):
        raise rv.RvError("voice.json: 最上位がオブジェクトでない")
    for k in v:
        if k not in VOICE_KEYS:
            raise rv.RvError("voice.json: 未知のキー '%s'" % k)
    if v.get("engine") not in ("voicevox", "say"):
        raise rv.RvError("voice.json.engine: voicevox か say（既定の声は持たない。利用者が選ぶ）")
    if not isinstance(v.get("voice"), str) or not v["voice"].strip():
        raise rv.RvError("voice.json.voice: 声の名前が無い（既定の声は持たない。利用者が選ぶ）")
    terms = v.get("terms")
    if not isinstance(terms, dict):
        raise rv.RvError("voice.json.terms: 規約の確認の記録が無い（voice.md の手順で利用者に確かめる）")
    for k in terms:
        if k not in TERMS_KEYS:
            raise rv.RvError("voice.json.terms: 未知のキー '%s'" % k)
    if terms.get("confirmed_by_user") is not True:
        raise rv.RvError("voice.json.terms.confirmed_by_user が true でない（利用者が規約を確かめた記録が無い）")
    for k in ("source", "summary", "use", "confirmed_on"):
        if not isinstance(terms.get(k), str) or not terms[k].strip():
            raise rv.RvError("voice.json.terms.%s: 規約の確認の記録に必要" % k)
    if not isinstance(terms.get("credit_required"), bool):
        raise rv.RvError("voice.json.terms.credit_required: 真偽値で記録する")
    credit = v.get("credit", "")
    if not isinstance(credit, str):
        raise rv.RvError("voice.json.credit: 文字列でない")
    if terms["credit_required"] and not credit.strip():
        raise rv.RvError("voice.json.credit が空（terms.credit_required が true のときは表記が要る）")
    for k in ("speed", "pause_scale"):
        if k in v and (not rv._num(v[k]) or v[k] <= 0):
            raise rv.RvError("voice.json.%s: 正の数でない" % k)
    if v["engine"] == "voicevox":
        if isinstance(v.get("speaker"), bool) or not isinstance(v.get("speaker"), int):
            raise rv.RvError("voice.json.speaker: voicevox のとき整数の style id が必要")
        if not isinstance(v.get("speaker_uuid"), str) or not v["speaker_uuid"]:
            raise rv.RvError("voice.json.speaker_uuid: voicevox のとき必要")


# ------------------------------------------------------------------ コマンド
def voiced_scenes(ctx):
    return [s for s in ctx.scenes if s["kind"] != "omit"]


def cmd_reading(args):
    ctx = rv.load_ctx(args.dir, args.profile)
    for sc in voiced_scenes(ctx):
        text = rv.reading_text(ctx, sc)
        if text:
            print("%s\t%s" % (sc["id"], text))
    return 0


def cmd_speakers(args):
    base = check_engine_url(args.engine_url)
    data = get_json(base, "/speakers")
    for sp in data:
        for st in sp.get("styles", []):
            print("%s\t%s\t%s\t%s" % (sp.get("name", ""), sp.get("speaker_uuid", ""),
                                      st.get("name", ""), st.get("id", "")))
    return 0


def cmd_policy(args):
    base = check_engine_url(args.engine_url)
    data = get_json(base, "/speaker_info?speaker_uuid=" + urllib.parse.quote(args.speaker_uuid))
    policy = data.get("policy", "")
    if not policy:
        raise rv.fail_ext("エンジンが policy を返さなかった（speaker_uuid: %s）" % args.speaker_uuid)
    sys.stdout.write(policy if policy.endswith("\n") else policy + "\n")
    return 0


def wav_duration(path_or_bytes):
    import io
    try:
        src = io.BytesIO(path_or_bytes) if isinstance(path_or_bytes, bytes) else path_or_bytes
        w = wave.open(src, "rb")
        try:
            return w.getnframes() / float(w.getframerate())
        finally:
            w.close()
    except (wave.Error, EOFError):
        raise rv.fail_ext("エンジンの応答が WAV として読めない")


def synth_voicevox(base, v, text):
    speaker = str(v["speaker"])
    q = http("POST", base, "/audio_query?speaker=%s&text=%s" % (speaker, urllib.parse.quote(text)))
    try:
        query = json.loads(q.decode("utf-8"))
    except ValueError:
        raise rv.fail_ext("エンジンの /audio_query の応答が JSON でない")
    query["speedScale"] = v.get("speed", 1.0)
    query["pauseLengthScale"] = v.get("pause_scale", 1.0)
    wav = http("POST", base, "/synthesis?speaker=" + speaker,
               data=json.dumps(query).encode("utf-8"), headers={"Content-Type": "application/json"})
    return wav


def run_say(voice, out, txt):
    if not shutil.which("say"):
        raise rv.fail_ext("say が PATH に無い")
    cmd = ["say"]
    if voice:
        cmd += ["-v", voice]
    cmd += ["-o", out, "-f", txt]
    try:
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as e:
        raise rv.fail_ext("say を起動できない（%s）" % e)
    if r.returncode != 0 or not os.path.exists(out):
        raise rv.fail_ext("say が失敗した（%s）" % (r.stderr or b"").decode("utf-8", "replace").strip()[:100])


def cmd_synth(args):
    base = check_engine_url(args.engine_url) if args.engine_url else DEFAULT_ENGINE_URL
    ctx = rv.load_ctx(args.dir, args.profile)
    scenes = voiced_scenes(ctx)
    texts = dict((s["id"], rv.reading_text(ctx, s)) for s in scenes)
    need = [s for s in scenes if texts[s["id"]]]
    v = ctx.voice
    if need:
        if v is None:
            raise rv.RvError("voice.json が無い（voice.md の手順で、利用者が声を選び規約を確かめる）")
        validate_voice(v)
        if v["engine"] == "say" and v.get("speed", 1.0) != 1.0:
            sys.stderr.write("注意: say では speed を使わない（声の速さは OS 側）\n")
    d = ctx.dir
    tmp = tempfile.mkdtemp(prefix=".audio-tmp-", dir=d)
    try:
        man = {}
        files = []
        for sc in scenes:
            sid = sc["id"]
            sha = rv.input_sha(ctx, "voice", sc)
            text = texts[sid]
            if not text:
                man[sid] = {"sha": sha, "silent": True}
                continue
            if v["engine"] == "voicevox":
                data = synth_voicevox(base, v, text)
                name = sid + ".wav"
                dur = wav_duration(data)
                with open(os.path.join(tmp, name), "wb") as f:
                    f.write(data)
            else:
                name = sid + ".aiff"
                txt = os.path.join(tmp, sid + ".txt")
                with open(txt, "w", encoding="utf-8") as f:
                    f.write(text)
                run_say(v["voice"], os.path.join(tmp, name), txt)
                dur = rv.probe_duration(os.path.join(tmp, name))
            files.append(name)
            man[sid] = {"sha": sha, "file": name, "duration": dur}
        outdir = os.path.join(d, "audio")
        os.makedirs(outdir, exist_ok=True)
        for name in files:
            dst = os.path.join(outdir, name)
            os.replace(os.path.join(tmp, name), dst)
        for sid, ent in man.items():
            if "file" in ent:
                ent["content"] = rv.file_sha(os.path.join(outdir, ent["file"]))
        rv.write_manifest(os.path.join(outdir, "manifest.json"), man)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("synth: %d 件を合成した（無音 %d 件）。measure で尺を確かめる" % (len(files), len(man) - len(files)))
    return 0


def cmd_trial(args):
    ctx = rv.load_ctx(args.dir, args.profile)
    tdir = os.path.join(ctx.dir, "trial")
    os.makedirs(tdir, exist_ok=True)
    have_say = shutil.which("say") is not None
    durs = {}
    est = False
    total = 0.0
    for sc in voiced_scenes(ctx):
        text = rv.reading_text(ctx, sc)
        if not text:
            continue
        sid = sc["id"]
        if have_say:
            txt = os.path.join(tdir, sid + ".txt")
            with open(txt, "w", encoding="utf-8") as f:
                f.write(text)
            out = os.path.join(tdir, sid + ".aiff")
            run_say(args.say_voice, out, txt)
            dur, estimated = rv.probe_duration(out), False
        else:
            dur, estimated = len(text) / rv.EST_CHARS_PER_SEC, True
        est = est or estimated
        durs[sid] = {"duration": dur, "estimated": estimated}
        total += dur
        print("%s\t%.1f\t%s" % (sid, dur, "推定" if estimated else "実測"))
    rv.write_manifest(os.path.join(tdir, "durations.json"), durs)
    print("音声の合計: %.1f 秒%s" % (total, "（推定を含む。say が無い）" if est else ""))
    return 0


def cmd_measure(args):
    ctx = rv.load_ctx(args.dir, args.profile)
    items, total = rv.timeline(ctx, trial=args.trial)
    est = False
    for it in items:
        mark = "推定" if it["source"] == "estimate" else it["source"]
        est = est or it["source"] == "estimate"
        print("%s\t%s\t音声 %.1f\t映像 %.1f\t長さ %.1f\t%s" % (
            it["id"], it["kind"], it["audio"], it["video"], it["length"], mark))
    print("total: %.1f / max: %.1f" % (total, ctx.max_seconds))
    if est:
        print("注意: 推定を含む（音声の実測も試し読みも無いシーンがある）")
    if total > ctx.max_seconds:
        print("over: %.1f" % (total - ctx.max_seconds))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="voice.py", description="release-video の声")
    sub = ap.add_subparsers(dest="cmd")
    sub.required = True

    def common(p, engine=False):
        p.add_argument("--dir", default=None)
        p.add_argument("--profile", default=None)
        if engine:
            p.add_argument("--engine-url", default=None)

    p = sub.add_parser("reading")
    common(p)
    p.set_defaults(fn=cmd_reading)
    p = sub.add_parser("speakers")
    p.add_argument("--engine", choices=["voicevox"], default="voicevox")
    p.add_argument("--engine-url", default=DEFAULT_ENGINE_URL)
    p.set_defaults(fn=cmd_speakers)
    p = sub.add_parser("policy")
    p.add_argument("--engine", choices=["voicevox"], default="voicevox")
    p.add_argument("--engine-url", default=DEFAULT_ENGINE_URL)
    p.add_argument("--speaker-uuid", required=True)
    p.set_defaults(fn=cmd_policy)
    p = sub.add_parser("trial")
    common(p)
    p.add_argument("--say-voice", default=None)
    p.set_defaults(fn=cmd_trial)
    p = sub.add_parser("synth")
    common(p, engine=True)
    p.set_defaults(fn=cmd_synth)
    p = sub.add_parser("measure")
    common(p)
    p.add_argument("--trial", action="store_true")
    p.set_defaults(fn=cmd_measure)
    args = ap.parse_args(argv)
    try:
        return args.fn(args)
    except rv.RvError as e:
        rv.die(e)
    except OSError as e:
        rv.die(rv.RvError("ファイルを読み書きできない（%s）" % e))


if __name__ == "__main__":
    sys.exit(main())
