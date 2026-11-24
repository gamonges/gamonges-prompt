# release-video の補助スクリプトの共通部分（読み込み・検証・ハッシュ・manifest・段の判定）。
# 編集したら: bash shared/scripts/tests/test-release-video.sh
# python 標準ライブラリだけ。/usr/bin/python3（3.9）でも動く書き方にする。
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

EXIT_ERR = 1
EXIT_ARG = 2
EXIT_EXT = 3

STAGES = ("script", "voice", "record", "cards", "compose")
DEFAULT_DIR = "./tmp/release-video"
DEFAULT_OUT = "release-video.mp4"
DEFAULT_MAX_SECONDS = 120
DEFAULT_GAP = 0.5
DEFAULT_BLUR = [r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"]
DEFAULT_BRAND = {
    "logo_text": "",
    "font_family": '"Hiragino Sans","Noto Sans JP",sans-serif',
    "colors": {
        "bg_from": "#0f1a36",
        "bg_to": "#1d3266",
        "text": "#ffffff",
        "accent": "#5fd3e6",
        "emphasis": "#ffd166",
        "muted": "#9fb3d9",
    },
}
KINDS = ("card", "record", "omit")
TABLE_BEGIN = "<!-- scenes:begin -->"
TABLE_END = "<!-- scenes:end -->"
ID_RE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z_-]{0,31}$")
COLOR_RE = re.compile(r"^#[0-9A-Fa-f]{3,8}$")
# 日本語の文字（ひらがな・カタカナ・漢字・全角形）。ソースにエスケープ列を書かないため chr で組む
JP = (
    chr(0x3005) + chr(0x3040) + "-" + chr(0x30FF) + chr(0x4E00) + "-" + chr(0x9FFF)
    + chr(0xFF00) + "-" + chr(0xFFEF)
)
FONT_RE = re.compile("^[A-Za-z0-9 ,\"'_." + JP + "\\-]*$")
EST_CHARS_PER_SEC = 6.0


class RvError(Exception):
    """利用者に 1 行で見せる誤り。code が終了コード。"""

    def __init__(self, msg, code=EXIT_ERR):
        Exception.__init__(self, msg)
        self.code = code


def fail_ext(msg):
    return RvError(msg, EXIT_EXT)


def die(err):
    sys.stderr.write("error: %s\n" % err)
    sys.exit(err.code if isinstance(err, RvError) else EXIT_ERR)


# ------------------------------------------------------------------ ハッシュ・ファイル
def canon(obj):
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def sha_obj(obj):
    return hashlib.sha256(canon(obj)).hexdigest()


def file_sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def atomic_write(path, data):
    """一時ファイルに書いてから置き換える（途中で落ちても半端なファイルを残さない）。"""
    if isinstance(data, str):
        data = data.encode("utf-8")
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".rv-tmp-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def read_json(path, what):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        raise RvError("%s が無い: %s" % (what, path))
    except ValueError as e:
        raise RvError("%s が JSON として読めない（%s）" % (what, e))
    except OSError as e:
        raise RvError("%s が読めない（%s）" % (what, e))


def read_manifest(path):
    if not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            m = json.load(f)
    except (ValueError, OSError):
        return None
    return m if isinstance(m, dict) else None


def write_manifest(path, obj):
    atomic_write(path, json.dumps(obj, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


def workdir(arg):
    return os.path.abspath(arg if arg else DEFAULT_DIR)


# ------------------------------------------------------------------ 設定ファイル
def default_sections():
    return [
        {"id": "intro", "label": "前置き", "required": False, "guide": "誰向けか"},
        {"id": "conclusion", "label": "結論", "required": True, "guide": "今まで→これから"},
        {"id": "value", "label": "価値", "required": True, "guide": "ユースケースと課題"},
        {"id": "demo", "label": "デモ", "required": True, "guide": "事前に撮った画面"},
        {"id": "omit", "label": "省略", "required": False, "guide": "枝葉の省略"},
        {"id": "caveat", "label": "注意点", "required": False, "guide": "注意点"},
        {"id": "future", "label": "今後", "required": False, "guide": "今後の予定"},
    ]


def _num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _unknown(obj, allowed, where):
    for k in obj:
        if k not in allowed:
            raise RvError("%s: 未知のキー '%s'" % (where, k))


def _str_field(obj, key, where):
    if key in obj and not isinstance(obj[key], str):
        raise RvError("%s.%s: 文字列でない" % (where, key))


def validate_profile(p, reserved=False):
    if not isinstance(p, dict):
        raise RvError("profile: 最上位がオブジェクトでない")
    allowed = ["talk", "brand", "privacy", "reading", "recording"]
    if reserved:
        allowed += ["_source", "_searched"]
    _unknown(p, allowed, "profile")
    talk = p.get("talk", {})
    if not isinstance(talk, dict):
        raise RvError("profile.talk: オブジェクトでない")
    _unknown(talk, ["name", "audience", "max_seconds", "tone", "sections"], "profile.talk")
    for k in ("name", "audience", "tone"):
        _str_field(talk, k, "profile.talk")
    if "max_seconds" in talk and (not _num(talk["max_seconds"]) or talk["max_seconds"] <= 0):
        raise RvError("profile.talk.max_seconds: 正の数でない")
    if "sections" in talk:
        secs = talk["sections"]
        if not isinstance(secs, list) or not secs:
            raise RvError("profile.talk.sections: 空でない配列でない")
        seen = set()
        for i, s in enumerate(secs):
            w = "profile.talk.sections[%d]" % i
            if not isinstance(s, dict):
                raise RvError("%s: オブジェクトでない" % w)
            _unknown(s, ["id", "label", "required", "guide"], w)
            if not isinstance(s.get("id"), str) or not ID_RE.match(s["id"]):
                raise RvError("%s.id: 不正な id" % w)
            if s["id"] in seen:
                raise RvError("profile.talk.sections: id '%s' が重複" % s["id"])
            seen.add(s["id"])
            _str_field(s, "label", w)
            _str_field(s, "guide", w)
            if "required" in s and not isinstance(s["required"], bool):
                raise RvError("%s.required: 真偽値でない" % w)
    brand = p.get("brand", {})
    if not isinstance(brand, dict):
        raise RvError("profile.brand: オブジェクトでない")
    _unknown(brand, ["logo_text", "font_family", "colors"], "profile.brand")
    _str_field(brand, "logo_text", "profile.brand")
    if "font_family" in brand:
        ff = brand["font_family"]
        if not isinstance(ff, str) or not FONT_RE.match(ff):
            raise RvError("profile.brand.font_family: 使えない文字を含む")
    colors = brand.get("colors", {})
    if not isinstance(colors, dict):
        raise RvError("profile.brand.colors: オブジェクトでない")
    for k, v in colors.items():
        if k not in DEFAULT_BRAND["colors"]:
            raise RvError("profile.brand.colors: 未知のキー '%s'" % k)
        if not isinstance(v, str) or not COLOR_RE.match(v):
            raise RvError("profile.brand.colors.%s: #rgb 形式の色でない" % k)
    priv = p.get("privacy", {})
    if not isinstance(priv, dict):
        raise RvError("profile.privacy: オブジェクトでない")
    _unknown(priv, ["blur_patterns", "blur_defaults"], "profile.privacy")
    if "blur_patterns" in priv:
        bp = priv["blur_patterns"]
        if not isinstance(bp, list) or not all(isinstance(x, str) and x for x in bp):
            raise RvError("profile.privacy.blur_patterns: 空でない文字列の配列でない")
    if "blur_defaults" in priv and not isinstance(priv["blur_defaults"], bool):
        raise RvError("profile.privacy.blur_defaults: 真偽値でない")
    rd = p.get("reading", {})
    if not isinstance(rd, dict):
        raise RvError("profile.reading: オブジェクトでない")
    _unknown(rd, ["replacements"], "profile.reading")
    reps = rd.get("replacements", [])
    if not isinstance(reps, list):
        raise RvError("profile.reading.replacements: 配列でない")
    for i, r in enumerate(reps):
        ok = (
            isinstance(r, dict) and set(r.keys()) == {"from", "to"}
            and isinstance(r["from"], str) and r["from"] and isinstance(r["to"], str)
        )
        if not ok:
            raise RvError("profile.reading.replacements[%d]: from と to の文字列の組でない" % i)
    rec = p.get("recording", {})
    if not isinstance(rec, dict):
        raise RvError("profile.recording: オブジェクトでない")
    _unknown(rec, ["base_url", "session"], "profile.recording")
    for k in ("base_url", "session"):
        _str_field(rec, k, "profile.recording")
    if reserved and "_searched" in p and not isinstance(p["_searched"], list):
        raise RvError("profile._searched: 配列でない")


def resolve_profile(d, arg):
    """設定を解決して作業ディレクトリの写し（profile.json）に置く。以後は写しだけを読む。"""
    copy_path = os.path.join(d, "profile.json")
    env = os.environ.get("RELEASE_VIDEO_PROFILE", "")
    searched = ["--profile", copy_path, "$RELEASE_VIDEO_PROFILE"]
    if arg:
        user = read_json(arg, "profile（設定ファイル）")
        validate_profile(user, reserved=False)
        new = dict(user)
        new["_source"] = os.path.abspath(arg)
        old = read_manifest(copy_path)
        if old is not None and sha_obj(old) != sha_obj(new):
            sys.stderr.write("設定を置き換えた（%s → %s）\n" % (sha_obj(old)[:8], sha_obj(new)[:8]))
        if old is None or sha_obj(old) != sha_obj(new):
            atomic_write(copy_path, json.dumps(new, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
        return new
    if os.path.exists(copy_path):
        p = read_json(copy_path, "設定の写し profile.json")
        validate_profile(p, reserved=True)
        return p
    if env:
        user = read_json(env, "設定ファイル（RELEASE_VIDEO_PROFILE）")
        validate_profile(user, reserved=False)
        new = dict(user)
        new["_source"] = os.path.abspath(env)
    else:
        new = {"_source": "none", "_searched": searched}
    atomic_write(copy_path, json.dumps(new, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    return new


def effective(profile):
    """既定を足した設定。"""
    talk = profile.get("talk", {})
    brand = profile.get("brand", {})
    colors = dict(DEFAULT_BRAND["colors"])
    colors.update(brand.get("colors", {}))
    priv = profile.get("privacy", {})
    patterns = list(DEFAULT_BLUR) if priv.get("blur_defaults", True) else []
    for p in priv.get("blur_patterns", []):
        if p not in patterns:
            patterns.append(p)
    return {
        "sections": talk.get("sections") or default_sections(),
        "brand": {
            "logo_text": brand.get("logo_text", DEFAULT_BRAND["logo_text"]),
            "font_family": brand.get("font_family", DEFAULT_BRAND["font_family"]),
            "colors": colors,
        },
        "blur_patterns": patterns,
        "replacements": profile.get("reading", {}).get("replacements", []),
        "recording": profile.get("recording", {}),
    }


# ------------------------------------------------------------------ 台本
SCENE_KEYS = ("id", "section", "kind", "seconds", "screen", "telop", "narr", "narr_reading", "card")
TOP_KEYS = ("version", "title", "max_seconds", "gap_seconds", "scenes")


def validate_scenes(obj, eff):
    if not isinstance(obj, dict):
        raise RvError("scenes.json: 最上位がオブジェクトでない")
    _unknown(obj, TOP_KEYS, "scenes.json")
    if obj.get("version") != 1:
        raise RvError("scenes.json.version: 1 でない")
    _str_field(obj, "title", "scenes.json")
    if "max_seconds" in obj and (not _num(obj["max_seconds"]) or obj["max_seconds"] <= 0):
        raise RvError("scenes.json.max_seconds: 正の数でない")
    if "gap_seconds" in obj and (not _num(obj["gap_seconds"]) or obj["gap_seconds"] < 0):
        raise RvError("scenes.json.gap_seconds: 0 以上の数でない")
    scenes = obj.get("scenes")
    if not isinstance(scenes, list) or not scenes:
        raise RvError("scenes.json.scenes: 空でない配列でない")
    sec_ids = set(s["id"] for s in eff["sections"])
    seen = set()
    for i, sc in enumerate(scenes):
        w = "scenes[%d]" % i
        if not isinstance(sc, dict):
            raise RvError("%s: オブジェクトでない" % w)
        _unknown(sc, SCENE_KEYS, w)
        sid = sc.get("id")
        if not isinstance(sid, str) or not ID_RE.match(sid):
            raise RvError("%s.id: 不正な id（英数字・_・- の 32 字以内）" % w)
        if sid in seen:
            raise RvError("%s.id: '%s' が重複" % (w, sid))
        seen.add(sid)
        kind = sc.get("kind")
        if kind not in KINDS:
            raise RvError("%s.kind: 未知の kind（card・record・omit のどれか）" % w)
        if sc.get("section") not in sec_ids:
            raise RvError("%s.section: 設定の段に無い '%s'" % (w, sc.get("section")))
        for k in ("screen", "telop"):
            if not isinstance(sc.get(k), str):
                raise RvError("%s.%s: 文字列でない" % (w, k))
        if not isinstance(sc.get("narr"), str):
            raise RvError("%s.narr: 文字列が必要（無いときは空文字）" % w)
        _str_field(sc, "narr_reading", w)
        if "seconds" in sc:
            if not _num(sc["seconds"]) or sc["seconds"] <= 0:
                raise RvError("%s.seconds: 正の数でない" % w)
        elif kind != "omit":
            raise RvError("%s.seconds: kind が %s のとき必須" % (w, kind))
        if kind == "card":
            card = sc.get("card")
            if not isinstance(card, dict):
                raise RvError("%s.card: kind が card のとき必須" % w)
            _unknown(card, ["kicker", "lines", "sub"], w + ".card")
            _str_field(card, "kicker", w + ".card")
            _str_field(card, "sub", w + ".card")
            lines = card.get("lines")
            if not isinstance(lines, list) or not lines or not all(isinstance(x, str) for x in lines):
                raise RvError("%s.card.lines: 文字列の配列でない" % w)
        elif "card" in sc:
            raise RvError("%s.card: kind が card のときだけ持てる" % w)


class Ctx(object):
    pass


def attach_scenes(ctx):
    ctx.obj = read_json(os.path.join(ctx.dir, "scenes.json"), "scenes.json")
    validate_scenes(ctx.obj, ctx.eff)
    ctx.scenes = ctx.obj["scenes"]
    ctx.gap = ctx.obj.get("gap_seconds", DEFAULT_GAP)
    ctx.max_seconds = ctx.obj.get("max_seconds", DEFAULT_MAX_SECONDS)


def load_ctx(dirarg, profile_arg=None, need_scenes=True):
    d = workdir(dirarg)
    ctx = Ctx()
    ctx.dir = d
    ctx.profile = resolve_profile(d, profile_arg) if os.path.isdir(d) else {}
    ctx.eff = effective(ctx.profile)
    ctx.obj = None
    ctx.scenes = []
    ctx.gap = DEFAULT_GAP
    ctx.max_seconds = DEFAULT_MAX_SECONDS
    ctx.voice = None
    vp = os.path.join(d, "voice.json")
    if os.path.exists(vp):
        ctx.voice = read_json(vp, "voice.json")
    if need_scenes:
        attach_scenes(ctx)
    return ctx


def scenes_sha(ctx):
    return sha_obj(ctx.obj)


# ------------------------------------------------------------------ 読み上げの整形
def _jp_class():
    return "[" + JP + "]"


def reading_text(ctx_or_eff, scene):
    eff = ctx_or_eff.eff if hasattr(ctx_or_eff, "eff") else ctx_or_eff
    if not scene.get("narr"):
        return ""
    if scene.get("narr_reading"):
        return scene["narr_reading"]
    text = scene["narr"]
    for ch in chr(0x300C) + chr(0x300D) + chr(0x300E) + chr(0x300F):
        text = text.replace(ch, "")
    # 空白を詰めてから置き換える（置き換え後の文字との間にも余計な空白が残らない）
    jp = _jp_class()
    text = re.sub("(?<=" + jp + ") +(?=[A-Za-z0-9])", "", text)
    text = re.sub("(?<=[A-Za-z0-9]) +(?=" + jp + ")", "", text)
    reps = sorted(eff["replacements"], key=lambda r: -len(r["from"]))
    if reps:
        pat = re.compile("|".join(re.escape(r["from"]) for r in reps))
        table = dict((r["from"], r["to"]) for r in reps)
        text = pat.sub(lambda m: table[m.group(0)], text)
    return text


# ------------------------------------------------------------------ 段ごとの入力の sha
def last_card_id(ctx):
    last = None
    for sc in ctx.scenes:
        if sc["kind"] == "card":
            last = sc["id"]
    return last


def credit_of(ctx):
    if ctx.voice and isinstance(ctx.voice.get("credit"), str):
        return ctx.voice["credit"]
    return ""


def overlay_sha(ctx):
    p = os.path.join(ctx.dir, "overlay.js")
    return file_sha(p) if os.path.exists(p) else ""


def input_sha(ctx, stage, scene):
    if stage == "voice":
        text = reading_text(ctx, scene)
        if not text:
            return sha_obj({"silent": True})
        v = ctx.voice or {}
        return sha_obj({
            "text": text,
            "engine": v.get("engine"), "voice": v.get("voice"), "speaker": v.get("speaker"),
            "speed": v.get("speed"), "pause_scale": v.get("pause_scale"),
        })
    if stage == "record":
        return sha_obj({
            "screen": scene["screen"], "telop": scene["telop"],
            "seconds": scene.get("seconds"), "overlay": overlay_sha(ctx),
        })
    if stage == "cards":
        credit = credit_of(ctx) if scene["id"] == last_card_id(ctx) else ""
        return sha_obj({
            "card": scene["card"], "telop": scene["telop"], "credit": credit,
            "brand": ctx.eff["brand"],
        })
    raise ValueError(stage)


STAGE_DIRS = {"voice": "audio", "record": "clips", "cards": "cards"}
STAGE_KINDS = {"voice": ("card", "record"), "record": ("record",), "cards": ("card",)}


def manifest_path(ctx, stage):
    return os.path.join(ctx.dir, STAGE_DIRS[stage], "manifest.json")


def stage_scenes(ctx, stage):
    return [s for s in ctx.scenes if s["kind"] in STAGE_KINDS[stage]]


def material_path(ctx, stage, entry):
    return os.path.join(ctx.dir, STAGE_DIRS[stage], entry["file"])


def clip_name(sid):
    return sid + ".webm"


def card_name(sid):
    return sid + ".png"


def compose_sha(ctx, out_name):
    """compose の入力の sha。omit 以外のシーンの順・素材の中身・gap・max_seconds。"""
    items = []
    man = {}
    for st in ("voice", "record", "cards"):
        man[st] = read_manifest(manifest_path(ctx, st)) or {}
    for sc in ctx.scenes:
        if sc["kind"] == "omit":
            continue
        sid = sc["id"]
        item = {"id": sid, "kind": sc["kind"]}
        a = man["voice"].get(sid, {})
        if sc.get("narr"):
            item["audio"] = a.get("content")
        else:
            item["seconds"] = sc.get("seconds")
        if sc["kind"] == "record":
            item["video"] = man["record"].get(sid, {}).get("content")
        else:
            item["video"] = man["cards"].get(sid, {}).get("content")
        items.append(item)
    return sha_obj({"scenes": items, "gap": ctx.gap, "max": ctx.max_seconds, "out": out_name})


# ------------------------------------------------------------------ 時間割
def timeline(ctx, trial=False):
    """kind が omit 以外のシーンごとの長さと合計。measure と compose だけがこれを使う。"""
    amap = read_manifest(manifest_path(ctx, "voice")) or {}
    cmap = read_manifest(manifest_path(ctx, "record")) or {}
    tmap = read_manifest(os.path.join(ctx.dir, "trial", "durations.json")) or {}
    items = []
    total = 0.0
    for sc in ctx.scenes:
        if sc["kind"] == "omit":
            continue
        sid = sc["id"]
        narr = sc.get("narr", "")
        secs = float(sc.get("seconds", 0))
        audio = 0.0
        src = "none"
        if narr:
            ent = amap.get(sid)
            if not trial and ent and "duration" in ent:
                audio, src = float(ent["duration"]), "audio"
            elif sid in tmap:
                audio, src = float(tmap[sid]["duration"]), "trial"
            else:
                audio, src = len(reading_text(ctx, sc)) / EST_CHARS_PER_SEC, "estimate"
        video = 0.0
        if sc["kind"] == "record":
            ent = cmap.get(sid)
            video = float(ent["duration"]) if ent and "duration" in ent else secs
        if narr:
            length = max(audio, video) + ctx.gap
        else:
            length = max(secs, video) + ctx.gap
        total += length
        items.append({"id": sid, "kind": sc["kind"], "audio": audio, "video": video,
                      "length": length, "source": src})
    return items, total


# ------------------------------------------------------------------ 撮影データの控え
def parse_data_changes(path):
    """「戻した日時」が空の行の (画面, 項目) を返す。ファイルが無ければ空。"""
    if not os.path.exists(path):
        return []
    rows = []
    idx = None
    with open(path, encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s.startswith("|"):
                continue
            cells = [c.strip() for c in s.strip("|").split("|")]
            if idx is None:
                if "戻した日時" in cells:
                    idx = {"back": cells.index("戻した日時"),
                           "screen": cells.index("画面") if "画面" in cells else 1,
                           "item": cells.index("項目") if "項目" in cells else 2}
                continue
            if all(re.match(r"^:?-+:?$", c) for c in cells if c):
                continue
            if len(cells) <= idx["back"]:
                continue
            if not cells[idx["back"]]:
                rows.append((cells[idx["screen"]] if len(cells) > idx["screen"] else "",
                             cells[idx["item"]] if len(cells) > idx["item"] else ""))
    return rows


# ------------------------------------------------------------------ 台本の表
def _cell(s):
    return str(s).replace("|", "\\|").replace("\r\n", "\n").replace("\n", "<br>")


def table_text(ctx):
    labels = dict((s["id"], s.get("label", s["id"])) for s in ctx.eff["sections"])
    lines = ["| id | 段 | 種別 | 尺（秒） | 画面と操作 | テロップ | ナレーション |",
             "|----|----|------|---------|-----------|---------|-------------|"]
    for sc in ctx.scenes:
        secs = sc.get("seconds")
        secs_s = ("%g" % secs) if secs is not None and sc["kind"] != "omit" else "―"
        lines.append("| %s | %s | %s | %s | %s | %s | %s |" % (
            _cell(sc["id"]), _cell(labels.get(sc["section"], sc["section"])), sc["kind"], secs_s,
            _cell(sc["screen"]), _cell(sc["telop"]), _cell(sc["narr"] or "―")))
    return "\n".join(lines)


def split_table(text):
    """script.md を (印の前＋開始の印, 間, 終了の印＋後) に分ける。印が 1 組でなければ None。"""
    if text.count(TABLE_BEGIN) != 1 or text.count(TABLE_END) != 1:
        return None
    i = text.index(TABLE_BEGIN) + len(TABLE_BEGIN)
    j = text.index(TABLE_END)
    if j < i:
        return None
    return text[:i], text[i:j], text[j:]


def set_status(text, status):
    """frontmatter の status の行だけを書き換える。"""
    if not text.startswith("---\n"):
        return text
    end = text.find("\n---", 4)
    if end < 0:
        return text
    head, rest = text[:end], text[end:]
    head = re.sub(r"(?m)^status:.*$", "status: " + status, head, count=1)
    return head + rest


def table_matches(ctx):
    p = os.path.join(ctx.dir, "script.md")
    if not os.path.exists(p):
        return False
    with open(p, encoding="utf-8") as f:
        parts = split_table(f.read())
    return parts is not None and parts[1].strip("\n") == table_text(ctx)


# ------------------------------------------------------------------ 段の判定
def _res(state, msg=""):
    return {"state": state, "msg": msg}


def stage_states(ctx_or_dir, profile_arg=None):
    """5 つの段の状態。status と compose の前提の拒否が共有する唯一の判定。"""
    out = []
    if isinstance(ctx_or_dir, Ctx):
        ctx = ctx_or_dir
    else:
        ctx = load_ctx(ctx_or_dir, profile_arg, need_scenes=False)
        try:
            attach_scenes(ctx)
        except RvError as e:
            out.append(("script", _res("todo", str(e))))
            for st in STAGES[1:]:
                out.append((st, _res("todo", "台本が読めない")))
            return out
    d = ctx.dir
    # script
    ap = os.path.join(d, "approved.json")
    appr = read_manifest(ap)
    if appr is None:
        out.append(("script", _res("todo", "利用者の確認待ち（approved.json が無い）")))
    elif appr.get("sha") != scenes_sha(ctx):
        out.append(("script", _res("stale", "承認の後に台本が変わった。再承認待ち")))
    elif not table_matches(ctx):
        out.append(("script", _res("stale", "script.md の表が scenes.json と違う。table を流す")))
    else:
        out.append(("script", _res("done")))
    # voice・record・cards
    for st in ("voice", "record", "cards"):
        targets = stage_scenes(ctx, st)
        man = read_manifest(manifest_path(ctx, st))
        if not targets:
            out.append((st, _res("done", "対象のシーンが無い")))
            continue
        if man is None:
            out.append((st, _res("todo", "manifest が無い")))
            continue
        missing, stale = [], []
        for sc in targets:
            sid = sc["id"]
            ent = man.get(sid)
            if ent is None:
                missing.append(sid)
                continue
            if ent.get("sha") != input_sha(ctx, st, sc):
                stale.append(sid)
                continue
            if st == "voice" and not sc.get("narr"):
                continue
            path = os.path.join(d, STAGE_DIRS[st], ent.get("file", ""))
            if not ent.get("file") or not os.path.isfile(path) or file_sha(path) != ent.get("content"):
                stale.append(sid)
        if stale:
            out.append((st, _res("stale", "入力か素材が変わった id: " + ", ".join(stale))))
        elif missing:
            out.append((st, _res("todo", "未記録の id: " + ", ".join(missing))))
        else:
            out.append((st, _res("done")))
    # record の追加の条件
    back = parse_data_changes(os.path.join(d, "data-changes.md"))
    if back:
        names = "、".join("%s・%s" % r for r in back)
        i = [s for s, _ in out].index("record")
        if out[i][1]["state"] == "done":
            out[i] = ("record", _res("restore", "撮影用データを戻していない: " + names))
        else:
            out[i][1]["msg"] += "（撮影用データも戻していない: %s）" % names
    # compose
    cm = read_manifest(os.path.join(d, "build", "manifest.json"))
    if cm is None:
        out.append(("compose", _res("todo", "build/manifest.json が無い")))
    else:
        outname = cm.get("file", DEFAULT_OUT)
        outpath = os.path.join(d, outname)
        if cm.get("sha") != compose_sha(ctx, outname):
            out.append(("compose", _res("stale", "素材か設定が変わった。合成し直す")))
        elif not os.path.isfile(outpath) or file_sha(outpath) != cm.get("content"):
            out.append(("compose", _res("stale", "出力 %s が無いか記録と違う" % outname)))
        elif cm.get("over"):
            out.append(("compose", _res("over", "尺が max_seconds を超えている。詰めて合成し直す")))
        else:
            out.append(("compose", _res("done")))
    return out


def next_stage(states):
    for st, r in states:
        if r["state"] != "done":
            return st
    return "none"


def probe_duration(path):
    """ffprobe で長さ（秒）を読む。読めなければ exit 3 の誤り。"""
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    except OSError:
        raise fail_ext("ffprobe を起動できない（PATH に無い）")
    txt = (r.stdout or "").strip().splitlines()
    try:
        val = float(txt[0]) if txt else None
    except ValueError:
        val = None
    if r.returncode != 0 or val is None or val <= 0:
        raise fail_ext("ffprobe で長さが読めない: %s" % os.path.basename(path))
    return val
