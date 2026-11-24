#!/usr/bin/env bash
# release-video の補助スクリプト（shared/skills/release-video/scripts/）の挙動テスト。
#
# 壊れても「それらしく」動き続けるものを守る:
#   - 台本の検証・承認・段の状態（scenes.py）: 古い承認や素材のまま次の段へ進む
#   - カード・重ね表示（render.py）: 他人の文字列が HTML・JS に埋まる（エスケープ漏れ）、ぼかしの式の黙った脱落
#   - 声（voice.py）: 規約の確認なしの合成、loopback 以外・プロキシ・リダイレクトでのナレーションの送信
#   - 合成（compose.py）: 前の段が揃わないままの合成、尺の超過、途中の出力の残り
# 外部のもの（ffmpeg・ffprobe・say・VOICEVOX）はすべて偽にする。実物には触れず、ネットワークの外に出ない。
#
# スクリプトは /usr/bin/python3（3.9）でも動かす前提なので、python3 と /usr/bin/python3 が
# 別物なら両方で全件を回す。テスト側の補助（JSON の読み書き）は python3 に固定する。
#
# 起動: bash shared/scripts/tests/test-release-video.sh

# set -e は使わない。1 件目の失敗で残りが走らなくなると、Red で全件の失敗を確かめられない
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
S="$REPO_ROOT/shared/skills/release-video/scripts"
REF="$REPO_ROOT/shared/skills/release-video/reference"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass_count=0
fail_count=0
skip_count=0
LABEL=""

pass() { echo -e "${GREEN}[PASS]${NC} ${LABEL}$1"; pass_count=$((pass_count + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} ${LABEL}$1"; fail_count=$((fail_count + 1)); }
skip() { echo -e "${YELLOW}[SKIP]${NC} ${LABEL}$1"; skip_count=$((skip_count + 1)); }

BASE="$(mktemp -d)"
cleanup() { rm -rf "$BASE"; }
trap cleanup EXIT

HPY="$(command -v python3)"

# ---------------------------------------------------------------- 偽のコマンド
# ffmpeg: 引数を 1 行ずつ $FAKE_DIR/ffmpeg.log に書き、最後の引数のファイルを作る。
#   FAKE_FFMPEG_FAIL=concat なら、結合のときだけ（途中の出力を作ってから）失敗する
# ffprobe: 最後の引数のファイル名ごとの長さを $FAKE_DIR/durations（「名前 秒」の行）から返す。無ければ 10.0
# say: -v・-o・-f を $FAKE_DIR/say.log に書き、-o のファイルを作る
BIN="$BASE/bin"
mkdir -p "$BIN"
cat > "$BIN/ffmpeg" <<'SH'
#!/usr/bin/env bash
[ -n "${FAKE_DIR:-}" ] || exit 9
last="${@: -1}"
printf '%s\n' "ffmpeg $*" >> "$FAKE_DIR/ffmpeg.log"
mkdir -p "$(dirname "$last")"
printf 'FAKE' > "$last"
if [ "${FAKE_FFMPEG_FAIL:-}" = "concat" ]; then
  case " $* " in *" concat "*) exit 1 ;; esac
fi
exit 0
SH
cat > "$BIN/ffprobe" <<'SH'
#!/usr/bin/env bash
[ -n "${FAKE_DIR:-}" ] || exit 9
last="${@: -1}"
name="$(basename "$last")"
v=""
if [ -f "$FAKE_DIR/durations" ]; then v="$(awk -v n="$name" '$1==n{print $2}' "$FAKE_DIR/durations" | head -n 1)"; fi
echo "${v:-10.0}"
SH
cat > "$BIN/say" <<'SH'
#!/usr/bin/env bash
[ -n "${FAKE_DIR:-}" ] || exit 9
voice=""; out=""; txt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -v) voice="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    -f) txt="$2"; shift 2 ;;
    *) shift ;;
  esac
done
{ printf 'voice=%s\n' "$voice"; printf 'text=%s\n' "$(cat "$txt" 2>/dev/null)"; } >> "$FAKE_DIR/say.log"
[ -n "$out" ] && printf 'AIFF' > "$out"
exit 0
SH
chmod +x "$BIN/ffmpeg" "$BIN/ffprobe" "$BIN/say"

# ---------------------------------------------------------------- テスト側の補助（python3 に固定）
HELPER="$BASE/helper.py"
cat > "$HELPER" <<'PY'
import json, os, sys

cmd = sys.argv[1]
if cmd == "mut":
    # mut <file> <python の文>: JSON を読み、d に文を当てて書き戻す
    d = json.load(open(sys.argv[2], encoding="utf-8"))
    exec(sys.argv[3], {"d": d})
    json.dump(d, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
elif cmd == "get":
    # get <file> <python の式>: JSON を読み、式の値を 1 行で出す
    d = json.load(open(sys.argv[2], encoding="utf-8"))
    print(eval(sys.argv[3], {"d": d}))
elif cmd == "reorder":
    # キーの並びと空白だけを変える（中身は同じ）
    d = json.load(open(sys.argv[2], encoding="utf-8"))
    def rev(o):
        if isinstance(o, dict):
            return {k: rev(o[k]) for k in sorted(o, reverse=True)}
        if isinstance(o, list):
            return [rev(x) for x in o]
        return o
    open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(rev(d), ensure_ascii=False, indent=7))
elif cmd == "cfg":
    # overlay.js の先頭の「window.__ovConfig = <JSON>;」を取り出して JSON で出す
    first = open(sys.argv[2], encoding="utf-8").readline().rstrip("\n")
    pre = "window.__ovConfig = "
    assert first.startswith(pre) and first.endswith(";"), first[:60]
    print(json.dumps(json.loads(first[len(pre):-1]), ensure_ascii=False))
elif cmd in ("voice-manifest", "compose-manifest"):
    # 偽の素材と manifest を、スクリプトの共通の関数で作る（status が done になる状態を作る補助）
    sys.path.insert(0, sys.argv[2])
    import rv_common
    ctx = rv_common.load_ctx(sys.argv[3])
    d = ctx.dir
    if cmd == "voice-manifest":
        man = {}
        os.makedirs(os.path.join(d, "audio"), exist_ok=True)
        for sc in ctx.scenes:
            if sc["kind"] == "omit":
                continue
            sha = rv_common.input_sha(ctx, "voice", sc)
            if not sc.get("narr"):
                man[sc["id"]] = {"sha": sha, "silent": True}
                continue
            name = sc["id"] + ".wav"
            p = os.path.join(d, "audio", name)
            open(p, "wb").write(b"WAV" + sc["id"].encode())
            man[sc["id"]] = {"sha": sha, "file": name, "content": rv_common.file_sha(p), "duration": 4.0}
        rv_common.write_manifest(os.path.join(d, "audio", "manifest.json"), man)
    else:
        out = sys.argv[4] if len(sys.argv) > 4 else "release-video.mp4"
        over = len(sys.argv) > 5 and sys.argv[5] == "over"
        os.makedirs(os.path.join(d, "build"), exist_ok=True)
        p = os.path.join(d, out)
        open(p, "wb").write(b"MP4")
        rv_common.write_manifest(os.path.join(d, "build", "manifest.json"), {
            "sha": rv_common.compose_sha(ctx, out), "file": out,
            "content": rv_common.file_sha(p), "duration": 30.0, "over": over})
PY

# ---------------------------------------------------------------- 台本の fixture（Claude が実際に書く形）
FIX_SCENES="$BASE/fixture-scenes.json"
cat > "$FIX_SCENES" <<'JSON'
{
  "version": 1,
  "title": "テスト機能",
  "max_seconds": 120,
  "gap_seconds": 0.5,
  "scenes": [
    {"id": "1", "section": "intro", "kind": "card", "seconds": 8, "screen": "タイトルカード",
     "telop": "概要", "narr": "新しい機能を紹介します。",
     "card": {"kicker": "小見出し", "lines": ["本文 1", "**強調**"], "sub": "補足"}},
    {"id": "2-1", "section": "demo", "kind": "record", "seconds": 10, "screen": "画面の操作",
     "telop": "操作 | 説明", "narr": "ここで 日本語 ABC を押します。"},
    {"id": "3", "section": "omit", "kind": "omit", "screen": "―", "telop": "省略した内容", "narr": ""},
    {"id": "4", "section": "caveat", "kind": "record", "seconds": 6, "screen": "補足の画面",
     "telop": "注意", "narr": ""},
    {"id": "5", "section": "future", "kind": "card", "seconds": 8, "screen": "締め", "telop": "今後",
     "narr": "ご要望をお寄せください。",
     "card": {"kicker": "今後", "lines": ["次の予定"], "sub": "お待ちください"}}
  ]
}
JSON

# 声の記録（say。特定の声の名前は使わない）
FIX_VOICE="$BASE/fixture-voice.json"
cat > "$FIX_VOICE" <<'JSON'
{"engine": "say", "voice": "TestVoice", "speed": 1.0, "pause_scale": 1.0, "credit": "",
 "terms": {"source": "OS の使用許諾", "summary": "要点", "use": "テスト", "credit_required": false,
           "confirmed_by_user": true, "confirmed_on": "2026-01-01"}}
JSON

FIX_SCRIPT="$BASE/fixture-script.md"
cat > "$FIX_SCRIPT" <<'MD'
---
type: Video Script
title: テスト機能のデモ動画の台本
description: テスト用
status: draft
---
# 台本

前の文。

<!-- scenes:begin -->
古い表
<!-- scenes:end -->

## 後ろの節

後ろの文。
MD

PROFILE_B="$BASE/profile-b.json"
cat > "$PROFILE_B" <<'JSON'
{"talk": {"sections": [{"id": "intro", "label": "前置き"}, {"id": "demo", "label": "デモ"},
                       {"id": "omit", "label": "省略"}, {"id": "caveat", "label": "注意"},
                       {"id": "future", "label": "今後"}]},
 "brand": {"logo_text": "LOGO-B", "colors": {"accent": "#112233"}},
 "reading": {"replacements": [{"from": "ABC", "to": "エービーシー"}]}}
JSON
PROFILE_A="$BASE/profile-a.json"
printf '{"talk": {"sections": [{"id": "only-a", "label": "A だけ"}]}}' > "$PROFILE_A"
PROFILE_C="$BASE/profile-c.json"
cat > "$PROFILE_C" <<'JSON'
{"talk": {"sections": [{"id": "intro", "label": "前置き"}, {"id": "demo", "label": "デモ"},
                       {"id": "omit", "label": "省略"}, {"id": "caveat", "label": "注意"},
                       {"id": "future", "label": "今後"}]},
 "brand": {"logo_text": "LOGO-C", "colors": {"accent": "#445566"}}}
JSON

H() { "$HPY" "$HELPER" "$@"; }

# ---------------------------------------------------------------- 検査の補助
assert_rc() { # 名前 期待 実際 [補足]
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: rc=$3（期待 $2）${4:+ — $4}"; fi
}
assert_has() { # 名前 ファイル 文字列
  if grep -qF -- "$3" "$2" 2>/dev/null; then pass "$1"; else fail "$1: 「$3」が無い（$(head -c 200 "$2" 2>/dev/null | tr '\n' ' ')）"; fi
}
assert_not_has() { # 名前 ファイル 文字列
  if grep -qF -- "$3" "$2" 2>/dev/null; then fail "$1: 「$3」がある"; else pass "$1"; fi
}
assert_one_line() { # 名前 ファイル
  local n; n="$(grep -c . "$2" 2>/dev/null || true)"
  if [ "$n" = "1" ]; then pass "$1"; else fail "$1: stderr が ${n} 行（$(head -c 200 "$2" | tr '\n' ' ')）"; fi
}
last_line() { grep . "$1" | tail -n 1; }
listing() { (cd "$1" && find . | LC_ALL=C sort); }

# 被検のスクリプトの実行。出力は $W/out と $W/err、終了コードは rc
PY=""
W=""
FAKE_DIR=""
ENVP=()
sc() { # スクリプト名 引数…
  local name="$1"; shift
  env FAKE_DIR="$FAKE_DIR" PATH="$BIN:$PATH" ${ENVP[@]+"${ENVP[@]}"} "$PY" "$S/$name" "$@" > "$W/out" 2> "$W/err"
  rc=$?
}

new_dir() { # 新しい作業ディレクトリ（空白と ' を含む）を作って D に入れる
  NDIR=$((NDIR + 1))
  D="$W/rv dry's $NDIR"
  mkdir -p "$D"
}
NDIR=0
D=""

# 全段 done の作業ディレクトリを作る（承認・表・声・録画・カード・合成）
mk_done() { # [profile]
  new_dir
  local prof=()
  [ $# -ge 1 ] && prof=(--profile "$1")
  cp "$FIX_SCENES" "$D/scenes.json"
  cp "$FIX_VOICE" "$D/voice.json"
  cp "$FIX_SCRIPT" "$D/script.md"
  sc scenes.py table --dir "$D" ${prof[@]+"${prof[@]}"} || true
  sc scenes.py approve --dir "$D"
  [ "$rc" -eq 0 ] || echo "mk_done: approve 失敗 $(cat "$W/err")" >&2
  "$HPY" "$HELPER" voice-manifest "$S" "$D"
  mkdir -p "$D/clips" "$D/cards"
  printf 'webm-2-1' > "$D/clips/2-1.webm"; printf 'webm-4' > "$D/clips/4.webm"
  printf 'png-1' > "$D/cards/1.png"; printf 'png-5' > "$D/cards/5.png"
  sc scenes.py mark --dir "$D" --stage record --id 2-1
  sc scenes.py mark --dir "$D" --stage record --id 4
  sc scenes.py mark --dir "$D" --stage cards --id 1
  sc scenes.py mark --dir "$D" --stage cards --id 5
  "$HPY" "$HELPER" compose-manifest "$S" "$D"
}

stage_line() { grep "^$1:" "$W/out" | head -n 1; }

# ================================================================ scenes.py
suite_scenes() {
  # --- validate: 正常
  new_dir; cp "$FIX_SCENES" "$D/scenes.json"
  sc scenes.py validate --dir "$D"
  assert_rc "validate: 正常な台本は exit 0" 0 "$rc" "$(head -n 1 "$W/err")"
  # 相対パス（cwd が repo の外）でも同じ
  (cd "$W" && env FAKE_DIR="$FAKE_DIR" PATH="$BIN:$PATH" "$PY" "$S/scenes.py" validate --dir "rv dry's $NDIR" > "$W/out" 2> "$W/err"); rc=$?
  assert_rc "validate: --dir に相対パスを渡しても exit 0（cwd に依存しない）" 0 "$rc" "$(head -n 1 "$W/err")"

  # --- validate: 誤り。exit 1・キー名を含む 1 行・新しいファイルができない
  bad_scene() { # 名前 python の文 期待するキー名
    new_dir; cp "$FIX_SCENES" "$D/scenes.json"
    sc scenes.py validate --dir "$D"   # 設定の写しを先に作っておく（以後の差分は検証の失敗によるものだけ）
    H mut "$D/scenes.json" "$2"
    listing "$D" > "$W/before"
    sc scenes.py validate --dir "$D"
    listing "$D" > "$W/after"
    if [ "$rc" -eq 1 ] && grep -qF -- "$3" "$W/err" && [ "$(grep -c . "$W/err")" -eq 1 ] && cmp -s "$W/before" "$W/after"; then
      pass "validate: $1 → exit 1・「$3」を含む 1 行・ファイルが増えない"
    else
      fail "validate: $1 → rc=${rc}、stderr=$(head -c 200 "$W/err" | tr '\n' ' ')（期待: 「$3」）"
    fi
  }
  bad_scene "id の重複" 'd["scenes"][1]["id"] = "1"' 'id'
  bad_scene "パスになる id" 'd["scenes"][1]["id"] = "../x"' 'id'
  bad_scene "空の id" 'd["scenes"][1]["id"] = ""' 'id'
  bad_scene "未知の kind" 'd["scenes"][1]["kind"] = "movie"' 'kind'
  bad_scene "シーンの未知のキー" 'd["scenes"][1]["colour"] = 1' 'colour'
  bad_scene "最上位の未知のキー" 'd["extra"] = 1' 'extra'
  bad_scene "kind: card で card 無し" 'del d["scenes"][0]["card"]' 'card'
  bad_scene "card の未知のキー" 'd["scenes"][0]["card"]["body"] = "x"' 'body'
  bad_scene "card.lines が文字列" 'd["scenes"][0]["card"]["lines"] = "x"' 'lines'
  bad_scene "設定の段に無い section" 'd["scenes"][1]["section"] = "zzz"' 'section'
  bad_scene "seconds が 0" 'd["scenes"][1]["seconds"] = 0' 'seconds'
  bad_scene "seconds が負" 'd["scenes"][1]["seconds"] = -3' 'seconds'
  bad_scene "seconds が文字列" 'd["scenes"][1]["seconds"] = "10"' 'seconds'
  bad_scene "seconds が真偽値" 'd["scenes"][1]["seconds"] = True' 'seconds'
  bad_scene "gap_seconds が負" 'd["gap_seconds"] = -1' 'gap_seconds'
  bad_scene "max_seconds が 0" 'd["max_seconds"] = 0' 'max_seconds'
  bad_scene "narr のキーが無い" 'del d["scenes"][1]["narr"]' 'narr'
  bad_scene "narr が文字列でない" 'd["scenes"][1]["narr"] = 5' 'narr'
  bad_scene "version が違う" 'd["version"] = 2' 'version'
  bad_scene "scenes が空" 'd["scenes"] = []' 'scenes'
  # JSON の構文エラーと、ファイルが無い
  new_dir; printf '{"version": 1,}' > "$D/scenes.json"
  sc scenes.py validate --dir "$D"
  if [ "$rc" -eq 1 ] && [ "$(grep -c . "$W/err")" -eq 1 ] && grep -q 'scenes.json' "$W/err"; then pass "validate: JSON の構文エラーは scenes.json を含む 1 行で exit 1"; else fail "validate: JSON の構文エラー rc=${rc} $(head -c 200 "$W/err")"; fi
  new_dir
  sc scenes.py validate --dir "$D"
  if [ "$rc" -eq 1 ] && grep -q 'scenes.json' "$W/err"; then pass "validate: scenes.json が無いと exit 1"; else fail "validate: scenes.json 無し rc=${rc}"; fi
  # 引数の誤りは exit 2
  sc scenes.py validate --nonsense
  assert_rc "validate: 引数の誤りは exit 2" 2 "$rc"

  # --- 設定ファイルの検証
  bad_profile() { # 名前 設定の内容 期待するキー名
    new_dir; cp "$FIX_SCENES" "$D/scenes.json"
    printf '%s' "$2" > "$W/p.json"
    sc scenes.py validate --dir "$D" --profile "$W/p.json"
    if [ "$rc" -eq 1 ] && grep -qF -- "$3" "$W/err" && [ "$(grep -c . "$W/err")" -eq 1 ] && [ ! -e "$D/profile.json" ]; then
      pass "profile: $1 → exit 1・「$3」を含む 1 行・写しを作らない"
    else
      fail "profile: $1 → rc=${rc}、stderr=$(head -c 200 "$W/err" | tr '\n' ' ')、写し=$([ -e "$D/profile.json" ] && echo 有 || echo 無)"
    fi
  }
  bad_profile "未知のキー" '{"foo": 1}' 'foo'
  bad_profile "利用者の設定に予約のキー _source" '{"_source": "x"}' '_source'
  bad_profile "色が CSS を壊す値" '{"brand": {"colors": {"accent": "red;}"}}}' 'accent'
  bad_profile "未知の色の名前" '{"brand": {"colors": {"neon": "#fff"}}}' 'neon'
  bad_profile "font_family に ; を含む" '{"brand": {"font_family": "a;b"}}' 'font_family'
  bad_profile "blur_patterns が配列でない" '{"privacy": {"blur_patterns": "x"}}' 'blur_patterns'
  bad_profile "段の id が重複" '{"talk": {"sections": [{"id": "a", "label": "x"}, {"id": "a", "label": "y"}]}}' 'sections'
  bad_profile "置き換え表の形が違う" '{"reading": {"replacements": [{"from": "a"}]}}' 'replacements'
  bad_profile "JSON でない" '{x' 'profile'

  # --- 設定の写し（AC-16）
  new_dir; cp "$FIX_SCENES" "$D/scenes.json"
  ENVP=(RELEASE_VIDEO_PROFILE="$PROFILE_A")
  sc scenes.py validate --dir "$D" --profile "$PROFILE_B"
  assert_rc "写し: 環境変数が A でも --profile B を使って検証が通る" 0 "$rc" "$(head -n 1 "$W/err")"
  if [ "$(H get "$D/profile.json" 'd["_source"]')" = "$PROFILE_B" ]; then pass "写し: 最初に解決した設定（B）が profile.json に写る"; else fail "写し: _source=$(H get "$D/profile.json" 'd.get("_source")')"; fi
  sc scenes.py validate --dir "$D"
  assert_rc "写し: 以後は --profile 無しでも B の値（段の一覧）で検証が通る（環境変数は A のまま）" 0 "$rc" "$(head -n 1 "$W/err")"
  sc scenes.py status --dir "$D"
  assert_rc "写し: status も写しを使う" 0 "$rc" "$(head -n 1 "$W/err")"
  ENVP=()
  # 設定なしで始めた後に環境変数を設定しても、写しが優先される
  new_dir; cp "$FIX_SCENES" "$D/scenes.json"
  sc scenes.py validate --dir "$D"
  assert_rc "写し: 設定なしでも検証が通る（既定の段）" 0 "$rc" "$(head -n 1 "$W/err")"
  if [ "$(H get "$D/profile.json" 'd["_source"]')" = "none" ]; then pass "写し: 設定なしは _source が none"; else fail "写し: 設定なしの _source"; fi
  if [ "$(H get "$D/profile.json" 'len(d["_searched"]) >= 1')" = "True" ]; then pass "写し: 探した場所を記録する"; else fail "写し: _searched が空"; fi
  ENVP=(RELEASE_VIDEO_PROFILE="$PROFILE_A")
  sc scenes.py validate --dir "$D"
  assert_rc "写し: 後から環境変数 A を設定しても写し（設定なし）が優先される" 0 "$rc" "$(head -n 1 "$W/err")"
  ENVP=()
  # 写しが無く環境変数だけ → 環境変数を写す
  new_dir; cp "$FIX_SCENES" "$D/scenes.json"
  ENVP=(RELEASE_VIDEO_PROFILE="$PROFILE_B")
  sc scenes.py validate --dir "$D"
  if [ "$rc" -eq 0 ] && [ "$(H get "$D/profile.json" 'd["_source"]')" = "$PROFILE_B" ]; then pass "写し: 写しが無ければ環境変数の設定を写す"; else fail "写し: 環境変数 rc=${rc}"; fi
  ENVP=()
  # --profile C で写しを置き換える → stderr に通知、設定に依存する段（cards）が stale
  mk_done "$PROFILE_B"
  sc scenes.py status --dir "$D"
  if [ "$(stage_line cards)" != "" ] && stage_line cards | grep -q done; then pass "写し: 置き換える前は cards が done"; else fail "写し: 置き換え前の cards: $(stage_line cards)"; fi
  sc scenes.py status --dir "$D" --profile "$PROFILE_C"
  assert_has "写し: --profile C で「設定を置き換えた」を stderr に出す" "$W/err" "設定を置き換えた"
  stage_line cards | grep -q stale && pass "写し: 置き換えると cards が stale" || fail "写し: cards=$(stage_line cards)"
  stage_line record | grep -q done && pass "写し: record は done のまま（brand に依存しない）" || fail "写し: record=$(stage_line record)"
  # 同じ設定を --profile で渡し直しても置き換えの通知は出ない
  sc scenes.py status --dir "$D" --profile "$PROFILE_C"
  assert_not_has "写し: 同じ中身なら置き換えの通知を出さない" "$W/err" "設定を置き換えた"

  # --- table
  new_dir; cp "$FIX_SCENES" "$D/scenes.json"; cp "$FIX_SCRIPT" "$D/script.md"
  sc scenes.py table --dir "$D"
  assert_rc "table: exit 0" 0 "$rc" "$(head -n 1 "$W/err")"
  "$HPY" - "$FIX_SCRIPT" "$D/script.md" "$W" <<'PY'
import sys
a = open(sys.argv[1], encoding="utf-8").read()
b = open(sys.argv[2], encoding="utf-8").read()
B, E = "<!-- scenes:begin -->", "<!-- scenes:end -->"
def split(s):
    i = s.index(B) + len(B); j = s.index(E)
    return s[:i], s[i:j], s[j:]
def nostatus(s):
    return "\n".join(l for l in s.split("\n") if not l.startswith("status:"))
a0, _, a2 = split(a)
b0, mid, b2 = split(b)
open(sys.argv[3] + "/table.mid", "w", encoding="utf-8").write(mid)
ok = nostatus(a0) == nostatus(b0) and a2 == b2
sys.exit(0 if ok else 1)
PY
  rc=$?
  assert_rc "table: 印の外は変わらない（frontmatter の status の行を除く）" 0 "$rc"
  assert_has "table: 表に id 2-1 の行がある" "$W/table.mid" "2-1"
  assert_has "table: セルの | はエスケープされる" "$W/table.mid" '操作 \| 説明'
  assert_not_has "table: 古い表は消える" "$W/table.mid" "古い表"
  cp "$D/script.md" "$W/script.once"
  sc scenes.py table --dir "$D"
  cmp -s "$W/script.once" "$D/script.md" && pass "table: 2 回流しても同じ" || fail "table: 2 回目で変わった"
  assert_has "table: 承認が無ければ status: draft" "$D/script.md" "status: draft"
  # 改行を含むセルは <br> にする（表が崩れない）
  H mut "$D/scenes.json" 'd["scenes"][0]["telop"] = "一行目\n二行目"'
  sc scenes.py table --dir "$D"
  assert_has "table: セルの改行は <br> にする" "$D/script.md" "一行目<br>二行目"
  # 印が無い・片方だけ → exit 1 でファイルに触れない
  for variant in none begin end; do
    new_dir; cp "$FIX_SCENES" "$D/scenes.json"
    case "$variant" in
      none) grep -v 'scenes:' "$FIX_SCRIPT" > "$D/script.md" ;;
      begin) grep -v 'scenes:end' "$FIX_SCRIPT" > "$D/script.md" ;;
      end) grep -v 'scenes:begin' "$FIX_SCRIPT" > "$D/script.md" ;;
    esac
    cp "$D/script.md" "$W/script.keep"
    sc scenes.py table --dir "$D"
    if [ "$rc" -eq 1 ] && cmp -s "$W/script.keep" "$D/script.md"; then pass "table: 印が${variant}のとき exit 1 でファイルに触れない"; else fail "table: 印が${variant} rc=${rc}"; fi
  done
  new_dir; cp "$FIX_SCENES" "$D/scenes.json"
  sc scenes.py table --dir "$D"
  assert_rc "table: script.md が無いと exit 1" 1 "$rc"

  # --- approve
  new_dir; cp "$FIX_SCENES" "$D/scenes.json"; cp "$FIX_SCRIPT" "$D/script.md"
  sc scenes.py approve --dir "$D"
  if [ "$rc" -eq 1 ] && [ ! -e "$D/approved.json" ]; then pass "approve: 表が古いと exit 1 で何も書かない"; else fail "approve: 表が古い rc=${rc}"; fi
  sc scenes.py table --dir "$D"
  sc scenes.py approve --dir "$D"
  assert_rc "approve: 表が一致していれば exit 0" 0 "$rc" "$(head -n 1 "$W/err")"
  if [ "$(H get "$D/approved.json" 'len(d["sha"])')" = "64" ] && [ -n "$(H get "$D/approved.json" 'd["date"]')" ]; then pass "approve: approved.json に sha（64 桁）と日付を書く"; else fail "approve: approved.json $(cat "$D/approved.json" 2>/dev/null)"; fi
  assert_has "approve: script.md を status: stable にする" "$D/script.md" "status: stable"
  new_dir; cp "$FIX_SCENES" "$D/scenes.json"; cp "$FIX_SCRIPT" "$D/script.md"
  sc scenes.py table --dir "$D"
  H mut "$D/scenes.json" 'd["scenes"][1]["kind"] = "movie"'
  sc scenes.py approve --dir "$D"
  if [ "$rc" -eq 1 ] && [ ! -e "$D/approved.json" ] && grep -q 'status: draft' "$D/script.md"; then pass "approve: validate が通らないと exit 1 で何も書かない"; else fail "approve: 不正な台本 rc=${rc}"; fi

  # --- status
  new_dir
  sc scenes.py status --dir "$D"
  assert_rc "status: 空のディレクトリでも exit 0" 0 "$rc" "$(head -n 1 "$W/err")"
  stage_line script | grep -q todo && pass "status: 空のディレクトリは script が todo" || fail "status: 空 script=$(stage_line script)"
  [ "$(last_line "$W/out")" = "next: script" ] && pass "status: 空のディレクトリの最後の行は next: script" || fail "status: 空 last=$(last_line "$W/out")"
  new_dir; cp "$FIX_SCENES" "$D/scenes.json"; cp "$FIX_SCRIPT" "$D/script.md"
  sc scenes.py table --dir "$D"
  sc scenes.py status --dir "$D"
  if stage_line script | grep -q todo && grep -q '確認待ち' "$W/out"; then pass "status: approved.json が無ければ script は todo（利用者の確認待ち）"; else fail "status: 承認なし $(stage_line script)"; fi

  mk_done
  sc scenes.py status --dir "$D"
  for st in script voice record cards compose; do
    stage_line "$st" | grep -q done && pass "status: 全段 done の fixture で $st が done" || fail "status: $st=$(stage_line "$st")（$(cat "$W/err" | head -n 2)）"
  done
  [ "$(last_line "$W/out")" = "next: none" ] && pass "status: 全部 done なら next: none" || fail "status: last=$(last_line "$W/out")"
  # AC-4: 承認の後に narr を変えて table → script が stale・next: script・status: draft
  H mut "$D/scenes.json" 'd["scenes"][0]["narr"] = "新しい機能を、紹介します。"'
  sc scenes.py table --dir "$D"
  sc scenes.py status --dir "$D"
  if stage_line script | grep -q stale && grep -q '再承認待ち' "$W/out" && [ "$(last_line "$W/out")" = "next: script" ] && grep -q 'status: draft' "$D/script.md"; then
    pass "status(AC-4): 承認の後に台本を変えると script が stale（再承認待ち）・next: script・script.md が draft"
  else
    fail "status(AC-4): script=$(stage_line script) last=$(last_line "$W/out")"
  fi
  sc scenes.py approve --dir "$D"
  sc scenes.py status --dir "$D"
  if stage_line script | grep -q done && stage_line voice | grep -q stale && stage_line record | grep -q done && stage_line cards | grep -q done && [ "$(last_line "$W/out")" = "next: voice" ]; then
    pass "status(AC-4): 再承認の後は voice だけが stale（record・cards は done）・next: voice"
  else
    fail "status(AC-4): voice=$(stage_line voice) record=$(stage_line record) cards=$(stage_line cards) last=$(last_line "$W/out")"
  fi
  # 承認の後に scenes.json を変えて table を流さない → 表が古い/承認が古い → stale
  mk_done
  H mut "$D/scenes.json" 'd["scenes"][1]["telop"] = "別のテロップ"'
  sc scenes.py status --dir "$D"
  stage_line script | grep -q stale && pass "status: 承認の後の変更（table 未実行）でも script は stale" || fail "status: script=$(stage_line script)"
  sc scenes.py table --dir "$D"
  sc scenes.py status --dir "$D"
  stage_line script | grep -q stale && grep -q '再承認' "$W/out" && pass "status: table の後も再承認まで stale" || fail "status: table 後 script=$(stage_line script)"
  # 表だけ古い（scenes.json は承認のとおり）→ stale（table を流す）
  mk_done
  "$HPY" - "$D/script.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(s.replace("省略した内容", "手で書き換えた"))
PY
  sc scenes.py status --dir "$D"
  if stage_line script | grep -q stale && grep -q 'table' "$W/out"; then pass "status: 表だけ古いと script は stale（table を流す）"; else fail "status: 表だけ古い script=$(stage_line script)"; fi
  # 各段の todo（manifest が無い）
  mk_done
  rm -f "$D/audio/manifest.json" "$D/clips/manifest.json" "$D/cards/manifest.json" "$D/build/manifest.json"
  sc scenes.py status --dir "$D"
  for st in voice record cards compose; do
    stage_line "$st" | grep -q todo && pass "status: manifest が無ければ $st は todo" || fail "status: $st=$(stage_line "$st")"
  done
  # sha の不一致（record の telop を変える。承認の前後で台本の変更は stale になるので承認し直す）
  mk_done
  H mut "$D/scenes.json" 'd["scenes"][1]["screen"] = "別の画面"'
  sc scenes.py table --dir "$D"; sc scenes.py approve --dir "$D"
  sc scenes.py status --dir "$D"
  stage_line record | grep -q stale && grep -q '2-1' <<<"$(stage_line record)" && pass "status: record の入力（screen）を変えると stale（どの id か）" || fail "status: record=$(stage_line record)"
  # AC-17: 同じ入力のまま素材だけ書き換える → record が stale、mark し直す → record は done・compose が stale
  mk_done
  printf 'webm-2-1-retake' > "$D/clips/2-1.webm"
  sc scenes.py status --dir "$D"
  stage_line record | grep -q stale && pass "status(AC-17): 同じ入力で素材だけ書き換えると record が stale（content の不一致）" || fail "status(AC-17): record=$(stage_line record)"
  sc scenes.py mark --dir "$D" --stage record --id 2-1
  sc scenes.py status --dir "$D"
  if stage_line record | grep -q done && stage_line compose | grep -q stale; then pass "status(AC-17): mark し直すと record は done・compose が stale"; else fail "status(AC-17): record=$(stage_line record) compose=$(stage_line compose)"; fi
  # gap_seconds を変える → compose だけ stale（承認のやり直しは要るが、voice・record・cards は影響を受けない）
  mk_done
  H mut "$D/scenes.json" 'd["gap_seconds"] = 1.5'
  sc scenes.py table --dir "$D"; sc scenes.py approve --dir "$D"
  sc scenes.py status --dir "$D"
  if stage_line compose | grep -q stale && stage_line voice | grep -q done && stage_line record | grep -q done && stage_line cards | grep -q done; then pass "status(AC-17): gap_seconds を変えると compose だけが stale"; else fail "status(AC-17): gap compose=$(stage_line compose) voice=$(stage_line voice)"; fi
  # 出力の中身が変わった → compose が stale
  mk_done
  printf 'tampered' > "$D/release-video.mp4"
  sc scenes.py status --dir "$D"
  stage_line compose | grep -q stale && pass "status: 出力の中身が記録と違えば compose は stale" || fail "status: tampered compose=$(stage_line compose)"
  # 出力が無い
  mk_done
  rm -f "$D/release-video.mp4"
  sc scenes.py status --dir "$D"
  stage_line compose | grep -qE 'todo|stale' && pass "status: 出力が無ければ compose は done でない" || fail "status: 出力なし compose=$(stage_line compose)"
  # restore: data-changes.md に「戻した日時」が空の行 → record が restore
  mk_done
  cat > "$D/data-changes.md" <<'MD'
---
type: Video Data Log
title: 撮影用データの控え
description: テスト
status: draft
---
| # | 画面 | 項目 | 元の値 | 撮影用の値 | 確認を取った日時 | 戻した日時 | 戻したことの確認 |
|---|------|------|--------|-----------|------------------|-----------|------------------|
| 1 | 設定画面 | 表示名 | 旧 | 新 | 2026-01-01 10:00 | | |
MD
  sc scenes.py status --dir "$D"
  if stage_line record | grep -q restore && grep -q '設定画面' "$W/out" && [ "$(last_line "$W/out")" = "next: record" ]; then pass "status(AC-15): 戻していない書き込みがあると record は restore・next: record"; else fail "status(AC-15): record=$(stage_line record) last=$(last_line "$W/out")"; fi
  "$HPY" - "$D/data-changes.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(s.replace("2026-01-01 10:00 | | |", "2026-01-01 10:00 | 2026-01-01 11:00 | 読み直して戻った |"))
PY
  sc scenes.py status --dir "$D"
  stage_line record | grep -q done && pass "status: 戻した日時を記録すれば record は done に戻る" || fail "status: 戻した後 record=$(stage_line record)"
  # over: build/manifest の over: true
  mk_done
  "$HPY" "$HELPER" compose-manifest "$S" "$D" release-video.mp4 over
  sc scenes.py status --dir "$D"
  if stage_line compose | grep -q over && ! stage_line compose | grep -q done; then pass "status(AC-18): over: true の compose は over（done にならない）"; else fail "status(AC-18): compose=$(stage_line compose)"; fi
  # sha の正規形: キーの並びと空白だけを変えても done のまま
  mk_done
  H reorder "$D/scenes.json"
  sc scenes.py status --dir "$D"
  [ "$(last_line "$W/out")" = "next: none" ] && pass "status: scenes.json のキーの並び・空白だけを変えても全段 done のまま（正規形の sha）" || fail "status: 正規形 last=$(last_line "$W/out") script=$(stage_line script)"

  # --- mark
  mk_done
  rm -f "$D/clips/manifest.json" "$D/cards/manifest.json"
  sc scenes.py mark --dir "$D" --stage record --id nosuch
  assert_rc "mark: 存在しない id は exit 1" 1 "$rc"
  sc scenes.py mark --dir "$D" --stage record --id 1
  assert_rc "mark: kind が段と合わない（card を record に）は exit 1" 1 "$rc"
  sc scenes.py mark --dir "$D" --stage cards --id 2-1
  assert_rc "mark: kind が段と合わない（record を cards に）は exit 1" 1 "$rc"
  sc scenes.py mark --dir "$D" --stage record --id 3
  assert_rc "mark: omit は exit 1" 1 "$rc"
  rm -f "$D/clips/2-1.webm"
  sc scenes.py mark --dir "$D" --stage record --id 2-1
  assert_rc "mark: ファイルが無ければ exit 1" 1 "$rc"
  [ ! -e "$D/clips/manifest.json" ] && pass "mark: 失敗したとき manifest を作らない" || fail "mark: 失敗後に manifest がある"
  sc scenes.py mark --dir "$D" --stage nothing --id 2-1
  assert_rc "mark: 未知の段は exit 2" 2 "$rc"
  printf 'webm' > "$D/clips/2-1.webm"
  printf '2-1.webm 12.5\n' > "$FAKE_DIR/durations"
  sc scenes.py mark --dir "$D" --stage record --id 2-1
  assert_rc "mark: 録画は exit 0" 0 "$rc" "$(head -n 1 "$W/err")"
  if [ "$(H get "$D/clips/manifest.json" 'd["2-1"]["duration"]')" = "12.5" ] && [ "$(H get "$D/clips/manifest.json" 'len(d["2-1"]["content"])')" = "64" ]; then pass "mark: duration（ffprobe）と content（中身の sha256）を書く"; else fail "mark: manifest $(cat "$D/clips/manifest.json" 2>/dev/null)"; fi
  # 長さが読めない（N/A）→ exit 3 で記録しない
  printf '4.webm N/A\n' > "$FAKE_DIR/durations"
  rm -f "$D/clips/manifest.json"
  sc scenes.py mark --dir "$D" --stage record --id 4
  if [ "$rc" -eq 3 ] && [ ! -e "$D/clips/manifest.json" ]; then pass "mark: ffprobe が N/A を返したら exit 3 で記録しない（seconds へ落とさない）"; else fail "mark: N/A rc=${rc} $(cat "$D/clips/manifest.json" 2>/dev/null)"; fi
  : > "$FAKE_DIR/durations"
  sc scenes.py mark --dir "$D" --stage cards --id 1
  assert_rc "mark: カードは exit 0" 0 "$rc" "$(head -n 1 "$W/err")"
  [ "$(H get "$D/cards/manifest.json" '"duration" in d["1"]')" = "False" ] && pass "mark: カードは duration を持たない" || fail "mark: カードの manifest $(cat "$D/cards/manifest.json")"
}

# ================================================================ render.py
suite_render() {
  # 悪意のある文字列を入れた台本・声の記録（クレジットはエスケープされ、最後のカードにだけ載る）
  new_dir; cp "$FIX_SCENES" "$D/scenes.json"; cp "$FIX_VOICE" "$D/voice.json"
  H mut "$D/scenes.json" 'd["scenes"][0]["card"] = {"kicker": "<b>k</b>", "lines": ["<script>alert(1)</script>", "a & b \"q\"", "**強調**"], "sub": "<i>s</i>"}'
  H mut "$D/voice.json" 'd["credit"] = "VC <b>x</b> & q"; d["terms"]["credit_required"] = True'
  sc render.py card --dir "$D" --profile "$PROFILE_B"
  assert_rc "card: exit 0" 0 "$rc" "$(head -n 1 "$W/err")"
  H1="$D/cards/1.html"; H5="$D/cards/5.html"
  [ -f "$H1" ] && [ -f "$H5" ] && pass "card: kind が card のシーンだけ html を作る（1・5）" || fail "card: html が無い $(ls "$D/cards" 2>&1 | tr '\n' ' ')"
  [ ! -e "$D/cards/2-1.html" ] && [ ! -e "$D/cards/3.html" ] && pass "card: record・omit の html は作らない" || fail "card: 余計な html"
  assert_has "card: lines の <script> はタグにならない（&lt;script）" "$H1" "&lt;script&gt;alert(1)&lt;/script&gt;"
  assert_not_has "card: 出力に <script 要素が無い" "$H1" "<script"
  assert_has "card: & と \" もエスケープされる" "$H1" "a &amp; b &quot;q&quot;"
  assert_has "card: **強調** だけが <b> になる" "$H1" "<b>強調</b>"
  assert_has "card: kicker の <b> はタグにならない" "$H1" "&lt;b&gt;k&lt;/b&gt;"
  assert_has "card: sub の <i> はタグにならない" "$H1" "&lt;i&gt;s&lt;/i&gt;"
  assert_has "card: クレジットは最後のカードにだけ載る（エスケープつき）" "$H5" "VC &lt;b&gt;x&lt;/b&gt; &amp; q"
  assert_not_has "card: 最初のカードにクレジットは載らない" "$H1" "VC "
  assert_has "card: 設定の色が CSS 変数に入る" "$H1" "--accent:#112233"
  assert_has "card: 設定のロゴの文字が入る" "$H1" "LOGO-B"
  [ ! -e "$D/cards/manifest.json" ] && pass "card: cards/manifest.json は書かない（確認の後に mark で記録する）" || fail "card: manifest を書いた"
  # 設定なしは既定の色・ロゴとクレジットの要素なし
  new_dir; cp "$FIX_SCENES" "$D/scenes.json"
  sc render.py card --dir "$D"
  assert_has "card: 設定なしは既定の色" "$D/cards/1.html" "--accent:#5fd3e6"
  assert_not_has "card: logo_text が空ならロゴの要素を出さない" "$D/cards/1.html" 'class="logo"'
  assert_not_has "card: クレジットが空ならクレジットの要素を出さない" "$D/cards/5.html" 'class="credit"'
  # 設定の logo_text もエスケープされる
  new_dir; cp "$FIX_SCENES" "$D/scenes.json"
  printf '{"brand": {"logo_text": "<i>L</i>"}}' > "$W/p.json"
  sc render.py card --dir "$D" --profile "$W/p.json"
  assert_has "card: logo_text もエスケープされる" "$D/cards/1.html" "&lt;i&gt;L&lt;/i&gt;"
  # 既定の font_family と同じ値は設定として通る
  cat > "$W/p.json" <<'JSON'
{"brand": {"font_family": "\"Hiragino Sans\",\"Noto Sans JP\",sans-serif"}}
JSON
  new_dir; cp "$FIX_SCENES" "$D/scenes.json"
  sc scenes.py validate --dir "$D" --profile "$W/p.json"
  assert_rc "profile: 既定と同じ font_family は通る（日本語・引用符・カンマ）" 0 "$rc" "$(head -n 1 "$W/err")"
  # credit_required: true でカードが 1 枚も無い → exit 1
  new_dir; cp "$FIX_SCENES" "$D/scenes.json"; cp "$FIX_VOICE" "$D/voice.json"
  H mut "$D/scenes.json" 'd["scenes"] = [s for s in d["scenes"] if s["kind"] != "card"]'
  H mut "$D/voice.json" 'd["credit"] = "VC"; d["terms"]["credit_required"] = True'
  sc render.py card --dir "$D"
  if [ "$rc" -eq 1 ] && [ "$(grep -c . "$W/err")" -eq 1 ] && grep -q 'クレジット' "$W/err"; then pass "card: クレジットが要るのにカードが無ければ exit 1"; else fail "card: カード無し rc=${rc} $(head -c 200 "$W/err")"; fi
  # 設定の写し（AC-16）: 環境変数 A・最初に --profile B → 以後の card は B の値
  new_dir; cp "$FIX_SCENES" "$D/scenes.json"
  ENVP=(RELEASE_VIDEO_PROFILE="$PROFILE_A")
  sc scenes.py validate --dir "$D" --profile "$PROFILE_B"
  sc render.py card --dir "$D"
  ENVP=()
  assert_rc "写し(card): --profile 無しでも写し（B）で card が通る" 0 "$rc" "$(head -n 1 "$W/err")"
  assert_has "写し(card): B の brand（ロゴ・色）が使われる" "$D/cards/1.html" "LOGO-B"

  # --- overlay
  new_dir; cp "$FIX_SCENES" "$D/scenes.json"
  sc render.py overlay --dir "$D" --profile "$PROFILE_B"
  assert_rc "overlay: exit 0" 0 "$rc" "$(head -n 1 "$W/err")"
  OV="$D/overlay.js"
  head -n 1 "$OV" | grep -q '^window.__ovConfig = ' && pass "overlay: 先頭に window.__ovConfig = がある" || fail "overlay: 先頭 $(head -c 80 "$OV")"
  H cfg "$OV" > "$W/cfg.json" 2>"$W/cfg.err" || fail "overlay: 設定の JSON が読めない $(cat "$W/cfg.err")"
  [ "$(H get "$W/cfg.json" 'd["accent"]')" = "#112233" ] && pass "overlay: 設定の accent が入る" || fail "overlay: accent"
  [ "$(H get "$W/cfg.json" 'len(d["blur_patterns"])')" = "1" ] && pass "overlay: 既定のぼかし（1 件）が入る" || fail "overlay: 既定 $(cat "$W/cfg.json")"
  if grep -q '@' "$W/cfg.json"; then pass "overlay: 既定の式にメールアドレスの形（@）がある"; else fail "overlay: 既定の式に @ が無い"; fi
  # 利用者の式は既定に足される。U+2028・U+2029 を含む式でも出力は ASCII だけ
  "$HPY" - "$W/p2.json" <<'PY'
import json, sys
pats = ["tel-[0-9]+", "x" + chr(0x2028) + "y" + chr(0x2029) + "z"]
json.dump({"privacy": {"blur_patterns": pats}}, open(sys.argv[1], "w"))
PY
  sc render.py overlay --dir "$D" --profile "$W/p2.json"
  assert_rc "overlay: U+2028・U+2029 を含む式でも exit 0" 0 "$rc" "$(head -n 1 "$W/err")"
  H cfg "$OV" > "$W/cfg.json"
  [ "$(H get "$W/cfg.json" 'len(d["blur_patterns"])')" = "3" ] && pass "overlay: blur_patterns は既定に足される（置き換わらない）" || fail "overlay: 足し合わせ $(cat "$W/cfg.json")"
  [ "$(H get "$W/cfg.json" 'd["blur_patterns"][1]')" = "tel-[0-9]+" ] && pass "overlay: 足した式が入る" || fail "overlay: 足した式"
  if head -n 1 "$OV" | LC_ALL=C grep -q '[^ -~]'; then fail "overlay: ASCII 以外の文字が出力にある（ensure_ascii でない）"; else pass "overlay: 出力は ASCII だけ（行区切り文字が生で入らない）"; fi
  if command -v node >/dev/null 2>&1 && node --version >/dev/null 2>&1; then
    cp "$OV" "$W/ov-check.js"
    if node --check "$W/ov-check.js" 2>"$W/node.err"; then pass "overlay: node --check が通る"; else fail "overlay: node --check $(head -n 3 "$W/node.err" | tr '\n' ' ')"; fi
  else
    skip "overlay: node が無いので構文を確かめていない"
  fi
  # blur_defaults: false → 既定が消えて設定の式だけ
  "$HPY" - "$W/p3.json" <<'PY'
import json, sys
json.dump({"privacy": {"blur_defaults": False, "blur_patterns": ["only-this"]}}, open(sys.argv[1], "w"))
PY
  sc render.py overlay --dir "$D" --profile "$W/p3.json"
  H cfg "$OV" > "$W/cfg.json"
  [ "$(H get "$W/cfg.json" 'd["blur_patterns"]')" = "['only-this']" ] && pass "overlay: blur_defaults: false で既定が消え、設定の式だけになる" || fail "overlay: defaults false $(cat "$W/cfg.json")"
  # 不正な式 → exit 1 で overlay.js を書かない（既存の overlay.js も変えない）
  new_dir; cp "$FIX_SCENES" "$D/scenes.json"; OV="$D/overlay.js"
  printf 'keep' > "$OV"
  printf '{"privacy": {"blur_patterns": ["("]}}' > "$W/p4.json"
  sc render.py overlay --dir "$D" --profile "$W/p4.json"
  if [ "$rc" -eq 1 ] && [ "$(cat "$OV")" = "keep" ] && grep -qF '(' "$W/err" && [ "$(grep -c . "$W/err")" -eq 1 ]; then pass "overlay: python で通らない式は exit 1・overlay.js を書かない"; else fail "overlay: 不正な式 rc=${rc} $(head -c 200 "$W/err")"; fi
  # python では通るが JS では通らない式（node がある場合）
  if command -v node >/dev/null 2>&1 && node --version >/dev/null 2>&1; then
    printf '{"privacy": {"blur_patterns": ["(?i)abc"]}}' > "$W/p5.json"
    printf 'keep' > "$OV"
    sc render.py overlay --dir "$D" --profile "$W/p5.json"
    if [ "$rc" -eq 1 ] && [ "$(cat "$OV")" = "keep" ]; then pass "overlay: JS で通らない式も exit 1・overlay.js を書かない"; else fail "overlay: JS の不正な式 rc=${rc}"; fi
  else
    skip "overlay: node が無いので JS だけで通らない式の拒否を確かめていない"
  fi
  # テンプレートの JS が不正な式を飛ばさず log に積む
  grep -q "badpattern" "$REF/overlay-template.js" && pass "overlay-template: 通らない式を badpattern として log に積む" || fail "overlay-template: badpattern が無い"
  grep -q "notfound" "$REF/overlay-template.js" && grep -q "MutationObserver" "$REF/overlay-template.js" && pass "overlay-template: notfound の記録と MutationObserver がある" || fail "overlay-template: notfound・MutationObserver"
}

run_suite() {
  PY="$1"
  W="$BASE/$(basename "$PY")-$RANDOM"
  mkdir -p "$W"
  FAKE_DIR="$W/fake"
  mkdir -p "$FAKE_DIR"
  LABEL="[$PY] "
  suite_scenes
  suite_render
}

# ================================================================ 実行
if [ ! -f "$S/scenes.py" ]; then
  echo "test-release-video.sh: 検査対象が見つからない: $S/scenes.py" >&2
  fail "scenes.py が無い"
fi

PY1="$(command -v python3)"
run_suite "$PY1"
if [ -x /usr/bin/python3 ] && [ "$(readlink -f "$PY1" 2>/dev/null || echo "$PY1")" != "$(readlink -f /usr/bin/python3 2>/dev/null || echo /usr/bin/python3)" ]; then
  run_suite /usr/bin/python3
fi

echo
echo "pass: $pass_count / fail: $fail_count / skip: $skip_count"
[ "$fail_count" -eq 0 ]
