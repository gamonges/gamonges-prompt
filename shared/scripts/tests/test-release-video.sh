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
     "telop": "操作 | 説明", "narr": "ここで日本語 ABC を押します。"},
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

# 前の段（承認・表・声・録画・カード）を実際の書き手（table・approve・voice.py synth・mark）で done にする
FAKE_DURS='1.aiff 3.0
2-1.aiff 4.0
5.aiff 2.0
2-1.webm 8.0
4.webm 6.0
release-video.mp4 50.0
'
# 出力の長さ（偽の ffprobe の返す値）だけを差し替える
set_out_dur() { # 秒
  { printf '%s' "$FAKE_DURS" | grep -v '^release-video.mp4 '; printf 'release-video.mp4 %s\n' "$1"; } > "$FAKE_DIR/durations"
}
mk_done_base() { # [profile]
  new_dir
  local prof=()
  [ -n "${1:-}" ] && prof=(--profile "$1")
  printf '%s' "$FAKE_DURS" > "$FAKE_DIR/durations"
  cp "$FIX_SCENES" "$D/scenes.json"
  cp "$FIX_VOICE" "$D/voice.json"
  cp "$FIX_SCRIPT" "$D/script.md"
  sc scenes.py table --dir "$D" ${prof[@]+"${prof[@]}"} || true
  sc scenes.py approve --dir "$D"
  [ "$rc" -eq 0 ] || echo "mk_done: approve 失敗 $(cat "$W/err")" >&2
  sc voice.py synth --dir "$D"
  [ "$rc" -eq 0 ] || echo "mk_done: synth 失敗 $(cat "$W/err")" >&2
  mkdir -p "$D/clips" "$D/cards"
  printf 'webm-2-1' > "$D/clips/2-1.webm"; printf 'webm-4' > "$D/clips/4.webm"
  printf 'png-1' > "$D/cards/1.png"; printf 'png-5' > "$D/cards/5.png"
  sc scenes.py mark --dir "$D" --stage record --id 2-1
  sc scenes.py mark --dir "$D" --stage record --id 4
  sc scenes.py mark --dir "$D" --stage cards --id 1
  sc scenes.py mark --dir "$D" --stage cards --id 5
}
mk_done() { # [profile]  全段 done（合成まで）
  mk_done_base "${1:-}"
  : > "$FAKE_DIR/ffmpeg.log"
  sc compose.py --dir "$D"
  [ "$rc" -eq 0 ] || echo "mk_done: compose 失敗 $(cat "$W/err")" >&2
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
  if ! grep -q 'section' "$W/out"; then pass "写し: status が B の段の一覧で台本を読む（A の一覧なら section の不一致になる）"; else fail "写し: status が A で読んだ $(head -n 2 "$W/out")"; fi
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
  # 控えの解析は fail-closed（regression: 列ずれ・見出し違い・欠けた行を「戻した」と読んで合成へ進んだ）。
  # 条件ごとに、その条件だけが崩れた控えを 1 つずつ当てる。status は読むだけなので、全段 done の D を使い回す
  mk_done
  DC_FM='---\ntype: Video Data Log\ntitle: t\ndescription: t\nstatus: draft\n---\n'
  DC_HEAD='| # | 画面 | 項目 | 元の値 | 撮影用の値 | 確認を取った日時 | 戻した日時 | 戻したことの確認 |'
  DC_SEP='|---|------|------|--------|-----------|------------------|-----------|------------------|'
  dc_case() { # 名前 期待（restore / done） 表の本文（見出しと区切りの後ろ。空なら行なし）[見出し]
    { printf "$DC_FM"; printf '%s\n%s\n' "${4:-$DC_HEAD}" "$DC_SEP"; [ -n "$3" ] && printf '%s\n' "$3"; } > "$D/data-changes.md"
    sc scenes.py status --dir "$D"
    if [ "$2" = restore ]; then
      if [ "$rc" -eq 0 ] && [ ! -s "$W/err" ] && stage_line record | grep -q restore && [ "$(last_line "$W/out")" = "next: record" ]; then pass "控え(fail-closed): $1 → record は restore・next: record"; else fail "控え(fail-closed): $1 → rc=${rc} record=$(stage_line record) last=$(last_line "$W/out") err=$(head -c 200 "$W/err")"; fi
    else
      if [ "$rc" -eq 0 ] && stage_line record | grep -q done && [ "$(last_line "$W/out")" = "next: none" ]; then pass "控え(止めすぎない): $1 → record は done"; else fail "控え(止めすぎない): $1 → rc=${rc} record=$(stage_line record) err=$(head -c 200 "$W/err")"; fi
    fi
  }
  dc_case "(a) 元の値に \\| を含み戻した日時が空" restore '| 1 | 設定画面 | 表示名 | A\|B | 新 | 2026-01-01 10:00 | | |'
  stage_line record | grep -q '設定画面・表示名' && pass "控え(fail-closed): (a) どの画面・項目かを出す" || fail "控え(fail-closed): (a) msg=$(stage_line record)"
  # (a') は 2 つずれると「戻した日時」「戻したことの確認」の位置に別の値が来て、両方とも埋まって見える
  dc_case "(a') エスケープしない | で列が見出しより多い" restore '| 1 | 設定画面 | 表示名 | A|B|C | 新 | 2026-01-01 10:00 | | 読み直して戻った |'
  dc_case "(b) 見出しが「戻した日」" restore '| 1 | 設定画面 | 表示名 | 旧 | 新 | 2026-01-01 10:00 | | |' '| # | 画面 | 項目 | 元の値 | 撮影用の値 | 確認を取った日時 | 戻した日 | 戻したことの確認 |'
  dc_case "(b') 見出しに「戻したことの確認」が無い" restore '| 1 | 設定画面 | 表示名 | 旧 | 新 | 2026-01-01 10:00 | 2026-01-01 11:00 |' '| # | 画面 | 項目 | 元の値 | 撮影用の値 | 確認を取った日時 | 戻した日時 |'
  dc_case "(c) 列が見出しより少ない途中の行" restore '| 1 | 設定画面 | 表示名 | 旧 |'
  dc_case "(d) 値が - だけの実データの行" restore '| - | - | - | - | - | - | | |'
  dc_case "(e) 戻した日時はあるが戻したことの確認が空" restore '| 1 | 設定画面 | 表示名 | 旧 | 新 | 2026-01-01 10:00 | 2026-01-01 11:00 | |'
  dc_case "(e') 戻した日時が - だけ" restore '| 1 | 設定画面 | 表示名 | 旧 | 新 | 2026-01-01 10:00 | - | 読み直して戻った |'
  dc_case "(f) UTF-8 として読めない控え" restore "$(printf '| 1 | \377\376 | x | 旧 | 新 | d | d | d |')"
  dc_case "(g) 行頭の | が欠けた未復元の行" restore '1 | 設定画面 | 表示名 | 旧 | 新 | 2026-01-01 10:00 | | |'
  dc_case "全行を戻した控え" done '| 1 | 設定画面 | 表示名 | 旧 | 新 | 2026-01-01 10:00 | 2026-01-01 11:00 | 読み直して戻った |'
  dc_case "\\| を含み戻した控え" done '| 1 | 設定画面 | 表示名 | A\|B | 新 | 2026-01-01 10:00 | 2026-01-01 11:00 | 読み直して戻った |'
  dc_case "見出しと区切りだけ（雛形のまま）" done ''
  dc_case "全セルが空の行だけ" done '|  |  |  |  |  |  |  |  |'
  dc_case "取り消せない操作を了承して実行し、了承の記録で閉じた行" done '| 1 | 通知 | 送信 | - | 送信済み | 2026-01-01 10:00 | 2026-01-01 10:05 | 取り消せない操作（利用者が了承） |'
  rm -f "$D/data-changes.md"
  # 台本が読めない作業ディレクトリ（作り直しで控えだけを引き継いだ直後の形）でも控えを読む
  new_dir
  { printf "$DC_FM"; printf '%s\n%s\n' "$DC_HEAD" "$DC_SEP"; printf '| 1 | 設定画面 | 表示名 | 旧 | 新 | 2026-01-01 10:00 | | |\n'; } > "$D/data-changes.md"
  sc scenes.py status --dir "$D"
  if [ "$rc" -eq 0 ] && stage_line record | grep -q todo && stage_line record | grep -q '撮影用データも戻していない' && stage_line record | grep -q '設定画面'; then pass "控え(fail-closed): 台本が無くても控えを読み、record の行に戻していない画面を出す（todo のまま）"; else fail "控え(fail-closed): 台本なし rc=${rc} record=$(stage_line record)"; fi

  # --- rebuild（作り直し。regression: 戻していない控えごと退避先へ移し、戻し忘れが見えなくなった）
  DC_PENDING='| 1 | 設定画面 | 表示名 | 旧 | 新 | 2026-01-01 10:00 | | |'
  DC_DONE='| 1 | 設定画面 | 表示名 | 旧 | 新 | 2026-01-01 10:00 | 2026-01-01 11:00 | 読み直して戻った |'
  dc_write() { { printf "$DC_FM"; printf '%s\n%s\n' "$DC_HEAD" "$DC_SEP"; printf '%s\n' "$2"; } > "$1/data-changes.md"; }
  bak_of() { sed -n 's/^rebuild: .* を \(.*\) へ退避した.*$/\1/p' "$W/out" | head -n 1; }
  leftovers() { ls -d "$D".bak-* "$D".new-* 2>/dev/null | grep -c . || true; }
  refuse_rebuild() { # 名前 [rebuild の追加の引数]
    listing "$D" > "$W/before"
    sc scenes.py rebuild --dir "$D" "${@:2}"
    listing "$D" > "$W/after"
    if [ "$rc" -eq 1 ] && cmp -s "$W/before" "$W/after" && [ "$(leftovers)" = "0" ] && [ "$(grep -c . "$W/err")" = "1" ]; then pass "rebuild: $1 → exit 1・何も動かさない・退避先も作業用も残らない"; else fail "rebuild: $1 → rc=${rc} 残り=$(leftovers) err=$(head -c 300 "$W/err")"; fi
  }
  mk_done; dc_write "$D" "$DC_PENDING"
  refuse_rebuild "戻していない控えがあり --carry が無い"
  if grep -q '先に戻' "$W/err" && grep -q -- '--carry' "$W/err" && grep -q '設定画面' "$W/err"; then pass "rebuild: 止めた 1 行に「先に戻す」「--carry」と画面の名前を出す"; else fail "rebuild: 止めた理由 $(cat "$W/err")"; fi
  new_dir; cp "$FIX_SCENES" "$D/scenes.json"
  BAD_HEAD='| # | 画面 | 項目 | 元の値 | 撮影用の値 | 確認を取った日時 | 戻した日 | 戻したことの確認 |'
  { printf "$DC_FM"; printf '%s\n%s\n%s\n' "$BAD_HEAD" "$DC_SEP" "$DC_PENDING"; } > "$D/data-changes.md"
  refuse_rebuild "読めない控え（見出しが違う）があり --carry が無い"
  # --carry: 控えを写してから入れ替える。引き継いだ控えは、前の段を置き直しても合成を止め続ける
  mk_done; dc_write "$D" "$DC_PENDING"
  listing "$D" > "$W/before"; cp "$D/data-changes.md" "$W/dc.keep"
  sc scenes.py rebuild --dir "$D" --carry
  BAK="$(bak_of)"
  if [ "$rc" -eq 0 ] && [ -n "$BAK" ] && [ -d "$BAK" ] && listing "$BAK" | cmp -s "$W/before" -; then pass "rebuild --carry: exit 0・退避先に元の全ファイルが残る"; else fail "rebuild --carry: rc=${rc} 退避先=${BAK} err=$(head -c 200 "$W/err")"; fi
  if [ "$(listing "$D" | tr '\n' ' ')" = ". ./data-changes.md " ] && cmp -s "$W/dc.keep" "$D/data-changes.md" && [ -z "$(ls -d "$D".new-* 2>/dev/null)" ]; then pass "rebuild --carry: 新しい作業ディレクトリには同じ中身の控えだけ・作業用が残らない"; else fail "rebuild --carry: D=$(listing "$D" | tr '\n' ' ')"; fi
  [ -n "$BAK" ] && cp -R "$BAK/." "$D/"
  sc scenes.py status --dir "$D"
  if [ -n "$BAK" ] && stage_line record | grep -q restore && [ "$(last_line "$W/out")" = "next: record" ]; then pass "rebuild --carry: 台本と素材を置き直すと、引き継いだ控えで record が restore・next: record"; else fail "rebuild --carry: 置き直した後 record=$(stage_line record) last=$(last_line "$W/out")"; fi
  # 戻していない行が無ければ、控えごと退避して空の作業ディレクトリにする
  for variant in restored none; do
    mk_done
    [ "$variant" = restored ] && dc_write "$D" "$DC_DONE"
    listing "$D" > "$W/before"
    sc scenes.py rebuild --dir "$D"
    BAK="$(bak_of)"
    if [ "$rc" -eq 0 ] && [ -n "$BAK" ] && listing "$BAK" | cmp -s "$W/before" - && [ "$(listing "$D")" = "." ] && [ "$(leftovers)" = "1" ]; then pass "rebuild: 控えが${variant}なら exit 0・全ファイルを退避して空の作業ディレクトリにする"; else fail "rebuild: ${variant} rc=${rc} 退避先=${BAK} D=$(listing "$D" 2>&1 | tr '\n' ' ') err=$(head -c 200 "$W/err")"; fi
  done
  # 控えの写しが失敗したら、何も動かさない（写し終えてから入れ替える順序）
  if [ "$(id -u)" = "0" ]; then
    skip "rebuild --carry: root では権限 000 でも読めるので、写しの失敗を作れない"
  else
    mk_done; dc_write "$D" "$DC_PENDING"; chmod 000 "$D/data-changes.md"
    refuse_rebuild "控えの写しが失敗する（--carry・控えの権限 000）" --carry
    chmod 644 "$D/data-changes.md"
  fi
  sc scenes.py rebuild --dir "$W/no such dir"
  assert_rc "rebuild: 作業ディレクトリが無ければ exit 1" 1 "$rc"
  # over: 出力の長さが max_seconds を超えた合成（偽の ffprobe が長い値を返す）
  mk_done
  set_out_dur 500.0
  sc compose.py --dir "$D"
  sc scenes.py status --dir "$D"
  if stage_line compose | grep -q over && ! stage_line compose | grep -q done; then pass "status(AC-18): over: true の compose は over（done にならない）"; else fail "status(AC-18): compose=$(stage_line compose)"; fi
  printf '%s' "$FAKE_DURS" > "$FAKE_DIR/durations"
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
  grep -q "notfound" "$REF/overlay-template.js" && pass "overlay-template: recording.md が読む log のキー notfound を保つ" || fail "overlay-template: notfound"
}

# ================================================================ voice.py
# 偽の VOICEVOX・偽のプロキシを 127.0.0.1 の空き port で起動する（port 0 で bind して port をファイルに書く）。
# どちらも受けた要求をログに書く（「届いた」「届かなかった」をそのファイルで判定する）
FAKE_SERVER="$BASE/fake_server.py"
cat > "$FAKE_SERVER" <<'PY'
import io, json, sys, wave
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

mode, portfile, logfile = sys.argv[1], sys.argv[2], sys.argv[3]
redirect_to = sys.argv[4] if len(sys.argv) > 4 else ""

def log(line):
    with open(logfile, "a", encoding="utf-8") as f:
        f.write(line + "\n")

def wav_bytes(seconds):
    b = io.BytesIO()
    w = wave.open(b, "wb")
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(8000)
    w.writeframes(b"\x00\x00" * int(8000 * seconds))
    w.close()
    return b.getvalue()

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def _send(self, code, body, ctype="application/json", headers=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)
    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""
    def do_ANY(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        body = self._body()
        log("%s %s" % (self.command, u.path))
        if mode == "proxy":
            return self._send(502, b"proxy")
        if mode == "redirect":
            return self._send(302, b"", headers={"Location": redirect_to})
        if u.path == "/audio_query":
            log("audio_query speaker=%s text=%s" % (q.get("speaker", [""])[0], q.get("text", [""])[0]))
            return self._send(200, json.dumps({"speedScale": 1.0, "pauseLengthScale": 1.0, "accent_phrases": []}).encode())
        if u.path == "/synthesis":
            d = json.loads(body.decode("utf-8"))
            log("synthesis speaker=%s speed=%s pause=%s" % (q.get("speaker", [""])[0], d.get("speedScale"), d.get("pauseLengthScale")))
            return self._send(200, wav_bytes(2.0 / float(d.get("speedScale") or 1.0)), "audio/wav")
        if u.path == "/speakers":
            return self._send(200, json.dumps([{"name": "テスト話者", "speaker_uuid": "uuid-1",
                                                  "styles": [{"name": "ノーマル", "id": 7}, {"name": "ささやき", "id": 8}]}], ensure_ascii=False).encode())
        if u.path == "/speaker_info":
            return self._send(200, json.dumps({"policy": "規約の本文（テスト）\n二行目"}, ensure_ascii=False).encode())
        return self._send(404, b"{}")
    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = do_ANY

srv = HTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
SERVER_PIDS=""
start_server() { # 名前 モード [リダイレクト先]  → $W/<名前>.port と $W/<名前>.log
  local name="$1" mode="$2" redirect="${3:-}"
  rm -f "$W/$name.port" "$W/$name.log"
  : > "$W/$name.log"
  "$HPY" "$FAKE_SERVER" "$mode" "$W/$name.port" "$W/$name.log" "$redirect" > /dev/null 2>&1 &
  SERVER_PIDS="$SERVER_PIDS $!"
  local i=0
  while [ ! -s "$W/$name.port" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  cat "$W/$name.port" 2>/dev/null
}
stop_servers() {
  local p
  for p in $SERVER_PIDS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  SERVER_PIDS=""
}
trap 'stop_servers; cleanup' EXIT

closed_port() { "$HPY" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }

VOICE_VV="$BASE/fixture-voice-vv.json"
cat > "$VOICE_VV" <<'JSON'
{"engine": "voicevox", "voice": "テスト話者（ノーマル）", "speaker": 7, "speaker_uuid": "uuid-1",
 "speed": 1.25, "pause_scale": 0.5, "credit": "",
 "terms": {"source": "エンジンの policy", "summary": "要点", "use": "テスト", "credit_required": false,
           "confirmed_by_user": true, "confirmed_on": "2026-01-01"}}
JSON

mk_voice_dir() { # [voice.json] → D に scenes.json・voice.json を置く
  new_dir; cp "$FIX_SCENES" "$D/scenes.json"; cp "${1:-$VOICE_VV}" "$D/voice.json"
}

suite_voice() {
  local PORT PPORT RPORT CPORT
  PORT="$(start_server vv normal)"
  PPORT="$(start_server proxy proxy)"
  RPORT="$(start_server redir redirect "http://127.0.0.1:$PPORT/x")"
  if [ -z "$PORT" ] || [ -z "$PPORT" ] || [ -z "$RPORT" ]; then fail "voice: 偽のエンジン・プロキシを起動できない"; stop_servers; return; fi
  local URL="http://127.0.0.1:$PORT"

  # --- reading（整形。期待値は文字列リテラル）
  new_dir; cp "$FIX_SCENES" "$D/scenes.json"
  "$HPY" - "$D/scenes.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
def sc(i, narr, **kw):
    s = {"id": i, "section": "intro", "kind": "record", "seconds": 5, "screen": "s", "telop": "t", "narr": narr}
    s.update(kw)
    return s
d["scenes"] = [
    sc("a", "「サブ機能」と『別名』を使う"),
    sc("b", "日本語 ABC 日本語"),
    sc("c", "使う ABC DEF"),
    sc("d", "ABC と AB"),
    sc("e", "「X」 Y", narr_reading="「そのまま」 Z"),
    sc("f", ""),
    sc("g", "省略", kind="omit"),
]
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False)
PY
  cat > "$W/rp.json" <<'JSON'
{"reading": {"replacements": [{"from": "AB", "to": "エー"}, {"from": "ABC", "to": "エービーシー"}]}}
JSON
  sc voice.py reading --dir "$D" --profile "$W/rp.json"
  assert_rc "reading: exit 0" 0 "$rc" "$(head -n 1 "$W/err")"
  printf 'a\tサブ機能と別名を使う\n' > "$W/want"
  grep -qxF "$(cat "$W/want")" "$W/out" && pass "reading: 「」『』を外す" || fail "reading: a $(cat "$W/out")"
  grep -qxF "$(printf 'b\t日本語エービーシー日本語')" "$W/out" && pass "reading: 置き換え表は長い from から当てる（ABC が AB より先）。空白を詰めた後に置き換える" || fail "reading: b $(cat "$W/out")"
  grep -qxF "$(printf 'd\tエービーシーとエー')" "$W/out" && pass "reading: 短い from が長い語を壊さない（ABC と AB が同じ文にある）" || fail "reading: d $(cat "$W/out")"
  grep -qxF "$(printf 'e\t「そのまま」 Z')" "$W/out" && pass "reading: narr_reading は整形を当てずそのまま使う" || fail "reading: e $(cat "$W/out")"
  grep -q '^f' "$W/out" && fail "reading: narr が空のシーンは出さない" || pass "reading: narr が空のシーンは出さない"
  grep -q '^g' "$W/out" && fail "reading: omit は出さない" || pass "reading: omit は出さない"
  # 置き換え表なし（写しが無い別ディレクトリ）で、空白の規則だけを見る
  mk_voice_dir
  "$HPY" - "$D/scenes.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
def sc(i, narr):
    return {"id": i, "section": "intro", "kind": "record", "seconds": 5, "screen": "s", "telop": "t", "narr": narr}
d["scenes"] = [sc("b", "日本語 ABC 日本語"), sc("c", "使う ABC DEF"), sc("h", "ABC DEF")]
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False)
PY
  sc voice.py reading --dir "$D"
  grep -qxF "$(printf 'b\t日本語ABC日本語')" "$W/out" && pass "reading: 日本語と英数字の間の半角空白を詰める" || fail "reading: b $(cat "$W/out")"
  grep -qxF "$(printf 'c\t使うABC DEF')" "$W/out" && pass "reading: 英字どうしの空白は残す（日本語との間だけ詰める）" || fail "reading: c $(cat "$W/out")"
  grep -qxF "$(printf 'h\tABC DEF')" "$W/out" && pass "reading: 英字だけの文の空白は残す" || fail "reading: h $(cat "$W/out")"

  # --- synth の拒否（audio/ を作らない）
  refuse() { # 名前 期待rc [synth の追加引数…]  ※ D・voice.json は呼び出し側で用意
    local name="$1" want="$2"; shift 2
    sc voice.py synth --dir "$D" "$@"
    if [ "$rc" -eq "$want" ] && [ ! -e "$D/audio" ] && [ "$(grep -c . "$W/err")" -ge 1 ]; then
      pass "synth: $name → exit ${want}・audio/ を作らない"
    else
      fail "synth: $name → rc=${rc}（期待 ${want}）audio=$([ -e "$D/audio" ] && echo 有 || echo 無) $(head -c 160 "$W/err" | tr '\n' ' ')"
    fi
  }
  new_dir; cp "$FIX_SCENES" "$D/scenes.json"
  refuse "voice.json が無い" 1 --engine-url "$URL"
  mk_voice_dir; H mut "$D/voice.json" 'd["terms"]["confirmed_by_user"] = False'
  refuse "confirmed_by_user が false" 1 --engine-url "$URL"
  mk_voice_dir; H mut "$D/voice.json" 'del d["terms"]["confirmed_by_user"]'
  refuse "confirmed_by_user が無い" 1 --engine-url "$URL"
  mk_voice_dir; H mut "$D/voice.json" 'd["terms"]["credit_required"] = True; d["credit"] = ""'
  refuse "credit_required なのに credit が空" 1 --engine-url "$URL"
  mk_voice_dir; H mut "$D/voice.json" 'del d["terms"]'
  refuse "terms が無い" 1 --engine-url "$URL"
  mk_voice_dir; H mut "$D/voice.json" 'd["terms"]["summary"] = ""'
  refuse "terms.summary が空（確認の記録の中身が無い）" 1 --engine-url "$URL"
  mk_voice_dir; H mut "$D/voice.json" 'd["speed"] = 0'
  refuse "speed が 0" 1 --engine-url "$URL"
  mk_voice_dir; H mut "$D/voice.json" 'd["colour"] = 1'
  refuse "voice.json の未知のキー" 1 --engine-url "$URL"
  mk_voice_dir; H mut "$D/voice.json" 'del d["engine"]'
  refuse "engine が無い（既定の声を持たない）" 1 --engine-url "$URL"
  mk_voice_dir; H mut "$D/voice.json" 'del d["voice"]'
  refuse "voice が無い（既定の声を持たない）" 1 --engine-url "$URL"
  mk_voice_dir
  refuse "engine-url が外部のホスト" 2 --engine-url "http://example.com:50021"
  refuse "engine-url が私的アドレス" 2 --engine-url "http://10.0.0.1:50021"
  refuse "engine-url が loopback に見せた名前" 2 --engine-url "http://127.0.0.1.example.com:50021"
  refuse "engine-url が https" 2 --engine-url "https://127.0.0.1:50021"
  mk_voice_dir; H mut "$D/voice.json" 'd["engine"] = "say"; d["voice"] = "TestVoice"; d["terms"]["confirmed_by_user"] = False'
  refuse "say でも確認が無ければ拒否" 1
  [ ! -s "$W/vv.log" ] && pass "synth: 拒否のとき偽のエンジンに要求が届かない" || fail "synth: 拒否なのにエンジンへ届いた $(head -c 200 "$W/vv.log")"

  # --- synth（voicevox）
  mk_voice_dir; : > "$W/vv.log"
  sc voice.py synth --dir "$D" --engine-url "$URL"
  assert_rc "synth(voicevox): exit 0" 0 "$rc" "$(head -n 1 "$W/err")"
  [ -f "$D/audio/1.wav" ] && [ -f "$D/audio/2-1.wav" ] && [ -f "$D/audio/5.wav" ] && pass "synth(voicevox): narr があるシーンの wav ができる" || fail "synth(voicevox): $(ls "$D/audio" 2>&1 | tr '\n' ' ')"
  [ ! -e "$D/audio/4.wav" ] && [ ! -e "$D/audio/3.wav" ] && pass "synth(voicevox): narr が空のシーン・omit は合成しない" || fail "synth(voicevox): 余計な wav"
  [ "$(grep -c '^audio_query ' "$W/vv.log")" = "3" ] && pass "synth(voicevox): /audio_query は narr のあるシーンだけ（3 件）" || fail "synth(voicevox): audio_query $(grep -c '^audio_query ' "$W/vv.log") 件"
  grep -qx 'audio_query speaker=7 text=ここで日本語ABCを押します。' "$W/vv.log" && pass "synth(voicevox): /audio_query に speaker と整形後の文が届く" || fail "synth(voicevox): $(grep '^audio_query' "$W/vv.log" | head -n 3 | tr '\n' '|')"
  [ "$(grep -c '^synthesis speaker=7 speed=1.25 pause=0.5$' "$W/vv.log")" = "3" ] && pass "synth(voicevox): /synthesis の body の speedScale・pauseLengthScale が voice.json の値" || fail "synth(voicevox): $(grep '^synthesis' "$W/vv.log" | head -n 3 | tr '\n' '|')"
  [ "$(H get "$D/audio/manifest.json" 'd["1"]["duration"]')" = "1.6" ] && pass "synth(voicevox): duration は wav の実際の長さ（2.0 秒 ÷ speed 1.25）" || fail "synth(voicevox): duration $(cat "$D/audio/manifest.json")"
  [ "$(H get "$D/audio/manifest.json" 'len(d["1"]["content"]) == 64 and d["1"]["file"] == "1.wav"')" = "True" ] && pass "synth(voicevox): manifest に content（sha256）と file" || fail "synth(voicevox): manifest"
  [ "$(H get "$D/audio/manifest.json" 'd["4"].get("silent") is True and "file" not in d["4"]')" = "True" ] && pass "synth(voicevox): narr が空のシーンは silent を記録する" || fail "synth(voicevox): silent $(H get "$D/audio/manifest.json" 'd["4"]')"
  [ "$(H get "$D/audio/manifest.json" '"3" in d')" = "False" ] && pass "synth(voicevox): omit は manifest に入れない" || fail "synth(voicevox): omit が manifest にある"
  # 書き手と読み手の整合: 台本を承認した状態で status の voice が done
  sc scenes.py validate --dir "$D"; cp "$FIX_SCRIPT" "$D/script.md"; sc scenes.py table --dir "$D"; sc scenes.py approve --dir "$D"
  sc scenes.py status --dir "$D"
  stage_line voice | grep -q done && pass "synth: 書いた manifest を status が done と読む" || fail "synth: status voice=$(stage_line voice)"
  H mut "$D/voice.json" 'd["speed"] = 1.1'
  sc scenes.py status --dir "$D"
  stage_line voice | grep -q stale && pass "synth: voice.json の speed を変えると voice が stale" || fail "synth: speed 変更 voice=$(stage_line voice)"
  # 無音だけの台本は voice.json が無くても通る（無音の合成で ffmpeg の経路だけ確かめる用）
  new_dir; cp "$FIX_SCENES" "$D/scenes.json"
  H mut "$D/scenes.json" 'for s in d["scenes"]: s["narr"] = ""'
  sc voice.py synth --dir "$D" --engine-url "$URL"
  if [ "$rc" -eq 0 ] && [ "$(H get "$D/audio/manifest.json" 'all(v.get("silent") for v in d.values())')" = "True" ]; then pass "synth: 全シーンが無音なら voice.json が無くても通り、すべて silent"; else fail "synth: 全無音 rc=${rc} $(head -c 200 "$W/err")"; fi
  # エンジンが落ちている → exit 3・1 行・audio/ が無い
  CPORT="$(closed_port)"
  mk_voice_dir
  sc voice.py synth --dir "$D" --engine-url "http://127.0.0.1:$CPORT"
  if [ "$rc" -eq 3 ] && [ "$(grep -c . "$W/err")" -eq 1 ] && grep -qF "エンジンに接続できない（http://127.0.0.1:${CPORT}）" "$W/err" && [ ! -e "$D/audio" ]; then pass "synth: エンジンが落ちていれば exit 3・「エンジンに接続できない（URL）」の 1 行・audio/ なし"; else fail "synth: エンジン停止 rc=${rc} $(head -c 200 "$W/err")"; fi
  if ls -A "$D" | grep -q '^\.audio-tmp-'; then fail "synth: エンジン停止の後に一時ディレクトリが残った"; else pass "synth: エンジン停止の後に一時ディレクトリを残さない"; fi
  # 設定の写し（AC-16）: 環境変数 A・最初に --profile B → synth は B の置き換え表で読む
  mk_voice_dir; : > "$W/vv.log"
  ENVP=(RELEASE_VIDEO_PROFILE="$PROFILE_A")
  sc scenes.py validate --dir "$D" --profile "$PROFILE_B"
  sc voice.py synth --dir "$D" --engine-url "$URL"
  ENVP=()
  grep -q 'audio_query speaker=7 text=ここで日本語エービーシー' "$W/vv.log" && pass "写し(synth): --profile 無しでも写し（B）の置き換え表で合成する" || fail "写し(synth): $(grep '^audio_query' "$W/vv.log" | head -n 3 | tr '\n' '|')"

  # --- AC-6: プロキシの環境変数・リダイレクトでもナレーションは loopback のエンジンにだけ届く
  mk_voice_dir; : > "$W/vv.log"; : > "$W/proxy.log"
  ENVP=(http_proxy="http://127.0.0.1:$PPORT" HTTP_PROXY="http://127.0.0.1:$PPORT" no_proxy= NO_PROXY=)
  sc voice.py synth --dir "$D" --engine-url "$URL"
  ENVP=()
  if [ "$rc" -eq 0 ] && [ -s "$W/vv.log" ] && [ ! -s "$W/proxy.log" ]; then pass "synth(AC-6): http_proxy を偽プロキシに向けても、要求は偽エンジンに届き、プロキシに 1 件も届かない"; else fail "synth(AC-6): rc=${rc} engine=$(wc -l < "$W/vv.log") proxy=$(wc -l < "$W/proxy.log")"; fi
  mk_voice_dir; : > "$W/proxy.log"
  sc voice.py synth --dir "$D" --engine-url "http://127.0.0.1:$RPORT"
  if [ "$rc" -eq 3 ] && [ ! -s "$W/proxy.log" ] && [ ! -e "$D/audio" ] && grep -q 'リダイレクト' "$W/err"; then pass "synth(AC-6): 302 は exit 3・リダイレクト先に要求が届かない・audio/ に何も書かない"; else fail "synth(AC-6): redirect rc=${rc} proxy=$(wc -l < "$W/proxy.log") $(head -c 200 "$W/err")"; fi

  # --- speakers・policy（利用者が規約を判断する文面をそのまま見せる）
  sc voice.py speakers --engine voicevox --engine-url "$URL"
  assert_rc "speakers: exit 0" 0 "$rc" "$(head -n 1 "$W/err")"
  grep -qxF "$(printf 'テスト話者\tuuid-1\tノーマル\t7')" "$W/out" && grep -qxF "$(printf 'テスト話者\tuuid-1\tささやき\t8')" "$W/out" && pass "speakers: 名前・uuid・スタイル名・style id を出す" || fail "speakers: $(cat "$W/out")"
  sc voice.py policy --engine voicevox --engine-url "$URL" --speaker-uuid uuid-1
  assert_rc "policy: exit 0" 0 "$rc" "$(head -n 1 "$W/err")"
  [ "$(cat "$W/out")" = "$(printf '規約の本文（テスト）\n二行目')" ] && pass "policy: エンジンの policy の文面をそのまま出す" || fail "policy: $(cat "$W/out")"
  sc voice.py speakers --engine voicevox --engine-url "http://example.com:50021"
  assert_rc "speakers: loopback 以外は exit 2" 2 "$rc"
  sc voice.py policy --engine voicevox --engine-url "http://10.0.0.1:50021" --speaker-uuid uuid-1
  assert_rc "policy: loopback 以外は exit 2" 2 "$rc"

  # --- synth（say）
  mk_voice_dir; H mut "$D/voice.json" 'd["engine"] = "say"; d["voice"] = "TestVoice"; del d["speaker"]; del d["speaker_uuid"]; d["speed"] = 1.0; d["pause_scale"] = 1.0'
  : > "$FAKE_DIR/say.log"; printf '1.aiff 3.5\n2-1.aiff 4.25\n5.aiff 2.0\n' > "$FAKE_DIR/durations"
  sc voice.py synth --dir "$D"
  assert_rc "synth(say): exit 0" 0 "$rc" "$(head -n 1 "$W/err")"
  [ "$(grep -c '^voice=TestVoice$' "$FAKE_DIR/say.log")" = "3" ] && pass "synth(say): say -v <voice> で 3 回呼ばれる" || fail "synth(say): $(cat "$FAKE_DIR/say.log" | tr '\n' '|')"
  grep -qxF 'text=ここで日本語ABCを押します。' "$FAKE_DIR/say.log" && pass "synth(say): -f の txt の中身は整形後の文" || fail "synth(say): $(cat "$FAKE_DIR/say.log" | tr '\n' '|')"
  [ -f "$D/audio/1.aiff" ] && [ -f "$D/audio/2-1.aiff" ] && pass "synth(say): audio/<id>.aiff ができる" || fail "synth(say): $(ls "$D/audio" 2>&1 | tr '\n' ' ')"
  [ "$(H get "$D/audio/manifest.json" 'd["2-1"]["duration"]')" = "4.25" ] && [ "$(H get "$D/audio/manifest.json" 'len(d["2-1"]["content"])')" = "64" ] && pass "synth(say): manifest に duration（ffprobe）と content" || fail "synth(say): manifest $(cat "$D/audio/manifest.json")"
  : > "$FAKE_DIR/durations"
  mk_voice_dir; H mut "$D/voice.json" 'd["engine"] = "say"; d["voice"] = "TestVoice"; d["terms"]["credit_required"] = True'
  refuse "say で credit_required なのに credit が空" 1

  # --- trial
  mk_voice_dir; : > "$FAKE_DIR/say.log"; printf '1.aiff 3.0\n2-1.aiff 4.0\n5.aiff 2.5\n' > "$FAKE_DIR/durations"
  sc voice.py trial --dir "$D"
  assert_rc "trial: exit 0" 0 "$rc" "$(head -n 1 "$W/err")"
  [ "$(grep -c '^voice=$' "$FAKE_DIR/say.log")" = "3" ] && pass "trial: --say-voice 無しでは -v を付けない（OS の既定の声。特定の声に固定しない）" || fail "trial: $(cat "$FAKE_DIR/say.log" | tr '\n' '|')"
  [ -f "$D/trial/1.aiff" ] && [ ! -e "$D/audio" ] && pass "trial: trial/ に書き、audio/ に触れない" || fail "trial: trial=$(ls "$D/trial" 2>&1 | tr '\n' ' ') audio=$([ -e "$D/audio" ] && echo 有 || echo 無)"
  grep -q '音声の合計: 9.5' "$W/out" && pass "trial: 合計秒（3.0 + 4.0 + 2.5）を出す" || fail "trial: 合計 $(cat "$W/out")"
  : > "$FAKE_DIR/say.log"
  sc voice.py trial --dir "$D" --say-voice SomeVoice
  [ "$(grep -c '^voice=SomeVoice$' "$FAKE_DIR/say.log")" = "3" ] && pass "trial: --say-voice を渡せば -v に使う" || fail "trial: --say-voice $(cat "$FAKE_DIR/say.log" | tr '\n' '|')"
  # say が無い環境 → 文字数からの推定と「推定」の表示
  mk_voice_dir
  mkdir -p "$BASE/emptybin"
  env FAKE_DIR="$FAKE_DIR" PATH="$BASE/emptybin" "$PY" "$S/voice.py" trial --dir "$D" > "$W/out" 2> "$W/err"; rc=$?
  assert_rc "trial: say が無くても exit 0（推定で進む）" 0 "$rc" "$(head -n 1 "$W/err")"
  grep -q '推定' "$W/out" && pass "trial: say が無いときは「推定」と表示する" || fail "trial: 推定の表示 $(cat "$W/out")"

  # --- measure（時間割。期待値は手計算: 音声 2.0 秒のシーン 3 つ）
  mk_voice_dir; H mut "$D/voice.json" 'd["speed"] = 1.0; d["pause_scale"] = 1.0'
  sc voice.py synth --dir "$D" --engine-url "$URL"
  # 1: 2.0+0.5=2.5 / 2-1: max(2.0, seconds 10)+0.5=10.5 / 4(無音 6 秒): 6.5 / 5: 2.5 → 合計 22.0
  sc voice.py measure --dir "$D"
  assert_rc "measure: exit 0" 0 "$rc" "$(head -n 1 "$W/err")"
  grep -q 'total: 22.0 / max: 120.0' "$W/out" && pass "measure: 時間割の合計（22.0）と max_seconds を出す" || fail "measure: $(cat "$W/out")"
  grep -q '^over:' "$W/out" && fail "measure: 上限内なのに over: が出た" || pass "measure: 上限内なら over: を出さない"
  # AC-18: 音声の合計（6.0）は max_seconds 以内でも、gap と録画で超えれば over:
  H mut "$D/scenes.json" 'd["max_seconds"] = 21'
  sc voice.py measure --dir "$D"
  if [ "$rc" -eq 0 ] && grep -q '^over: 1.0$' "$W/out"; then pass "measure(AC-18): 音声は上限内でも gap・映像を足して超えれば exit 0 のまま over: 1.0"; else fail "measure(AC-18): rc=${rc} $(cat "$W/out")"; fi
  H mut "$D/scenes.json" 'd["max_seconds"] = 21; d["gap_seconds"] = 0'
  sc voice.py measure --dir "$D"
  grep -q 'total: 20.0 / max: 21.0' "$W/out" && pass "measure: gap_seconds を 0 にすると合計が gap の分だけ減る（20.0）" || fail "measure: gap 0 $(cat "$W/out")"
  # --trial: trial の長さを使う（audio の manifest より優先）
  H mut "$D/scenes.json" 'd["max_seconds"] = 120; d["gap_seconds"] = 0.5'
  mkdir -p "$D/trial"; printf '{"1": {"duration": 1.0, "estimated": false}, "2-1": {"duration": 1.0, "estimated": false}, "5": {"duration": 1.0, "estimated": false}}' > "$D/trial/durations.json"
  sc voice.py measure --dir "$D" --trial
  grep -q 'total: 20.0 / max: 120.0' "$W/out" && pass "measure --trial: 試し読みの長さで見積もる（1.5 / 10.5 / 6.5 / 1.5）" || fail "measure --trial: $(cat "$W/out")"
  # 実測が無く、trial も無い → 文字数からの推定（1 秒 6 字）と「推定」の表示
  mk_voice_dir
  sc voice.py measure --dir "$D"
  grep -q '推定' "$W/out" && pass "measure: 音声が無ければ文字数からの推定と表示する" || fail "measure: 推定 $(cat "$W/out")"
  stop_servers
}

# ================================================================ compose.py
# 前の段を実際の書き手（voice.py synth・scenes.py mark）で done にした作業ディレクトリを作る
# 時間割: 1(card) 3.0+0.5 / 2-1(record) max(4.0, 録画 8.0)+0.5 / 4(無音 record) max(6, 6.0)+0.5 / 5(card) 2.0+0.5 → 21.0

mk_prereq() { # [profile]  compose の手前（compose はまだ流さない）
  mk_done_base "${1:-}"
}

suite_compose() {
  # --- 前提の拒否: 前の段が done でなければ ffmpeg を 1 回も呼ばない（AC-9）
  refuse_compose() { # 名前 期待する段
    if [ "$rc" -eq 1 ] && grep -q "$2" "$W/err" && [ ! -s "$FAKE_DIR/ffmpeg.log" ] && [ ! -e "$D/release-video.mp4" ]; then
      pass "compose: $1 → exit 1・「$2」を含む・ffmpeg を呼ばない"
    else
      fail "compose: $1 → rc=${rc} stderr=$(head -c 200 "$W/err" | tr '\n' ' ') ffmpeg=$(wc -l < "$FAKE_DIR/ffmpeg.log" 2>/dev/null)"
    fi
  }
  mk_prereq; rm -f "$FAKE_DIR/ffmpeg.log"
  H mut "$D/voice.json" 'd["voice"] = "OtherVoice"'
  sc compose.py --dir "$D"; refuse_compose "voice が stale" "voice"
  mk_prereq; rm -f "$FAKE_DIR/ffmpeg.log"
  rm -f "$D/cards/manifest.json"
  sc compose.py --dir "$D"; refuse_compose "cards が todo" "cards"
  mk_prereq; rm -f "$FAKE_DIR/ffmpeg.log"
  printf 'retake' > "$D/clips/2-1.webm"
  sc compose.py --dir "$D"; refuse_compose "record が stale（素材の撮り直し）" "record"
  grep -q '2-1' "$W/err" && pass "compose: 拒否の 1 行にどの id かが入る" || fail "compose: id が無い $(cat "$W/err")"
  mk_prereq; rm -f "$FAKE_DIR/ffmpeg.log"
  printf '| 1 | 画面 | 項目 | 元 | 新 | 2026-01-01 | | |\n' > "$W/row"
  { printf '| # | 画面 | 項目 | 元の値 | 撮影用の値 | 確認を取った日時 | 戻した日時 | 戻したことの確認 |\n|---|---|---|---|---|---|---|---|\n'; cat "$W/row"; } > "$D/data-changes.md"
  sc compose.py --dir "$D"; refuse_compose "record が restore（戻していない書き込み）" "record"
  mk_prereq; rm -f "$FAKE_DIR/ffmpeg.log"
  H mut "$D/scenes.json" 'd["scenes"][0]["narr"] = "変えた。"'
  sc compose.py --dir "$D"; refuse_compose "script が stale（承認の後に台本を変えた）" "script"
  new_dir; rm -f "$FAKE_DIR/ffmpeg.log"
  sc compose.py --dir "$D"
  if [ "$rc" -eq 1 ] && [ ! -s "$FAKE_DIR/ffmpeg.log" ]; then pass "compose: 空のディレクトリは exit 1・ffmpeg を呼ばない"; else fail "compose: 空 rc=${rc}"; fi

  # --- ffmpeg が PATH に無い → exit 3（前の段は揃っている）
  mk_prereq
  env FAKE_DIR="$FAKE_DIR" PATH="$BASE/emptybin" "$PY" "$S/compose.py" --dir "$D" > "$W/out" 2> "$W/err"; rc=$?
  if [ "$rc" -eq 3 ] && grep -q 'ffmpeg' "$W/err" && [ ! -e "$D/release-video.mp4" ]; then pass "compose: ffmpeg が PATH に無ければ exit 3・出力を作らない"; else fail "compose: ffmpeg 無し rc=${rc} $(head -c 200 "$W/err")"; fi

  # --- 合成の形（偽の ffmpeg の argv）
  mk_prereq "$PROFILE_B"; rm -f "$FAKE_DIR/ffmpeg.log"
  ENVP=(RELEASE_VIDEO_PROFILE="$PROFILE_A")
  sc compose.py --dir "$D"
  ENVP=()
  assert_rc "compose: 前の段が揃っていれば exit 0（環境変数が A でも写しの B を使う。AC-16）" 0 "$rc" "$(head -n 1 "$W/err")"
  LOG="$FAKE_DIR/ffmpeg.log"
  [ "$(grep -c . "$LOG")" = "5" ] && pass "compose: ffmpeg はシーン 4 つ（omit を除く）と結合 1 回の計 5 回" || fail "compose: ffmpeg の回数 $(grep -c . "$LOG")"
  L1="$(grep 'build/1.mp4' "$LOG" | head -n 1)"; L2="$(grep 'build/2-1.mp4' "$LOG" | head -n 1)"
  L4="$(grep 'build/4.mp4' "$LOG" | head -n 1)"; L5="$(grep 'build/5.mp4' "$LOG" | head -n 1)"
  has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
  has "$L1" "-loop 1" && has "$L1" "cards/1.png" && has "$L1" "audio/1.aiff" && has "$L1" "-t 3.500" && pass "compose(card): -loop 1・cards/1.png・audio/1.aiff・-t 3.500（音声 3.0 + gap 0.5）" || fail "compose(card): $L1"
  has "$L2" "clips/2-1.webm" && has "$L2" "audio/2-1.aiff" && has "$L2" "-t 8.500" && has "$L2" "tpad=stop_mode=clone:stop_duration=0.500" && has "$L2" "apad" && pass "compose(record): tpad・apad・-t 8.500（max(音声 4.0, 録画 8.0) + gap）" || fail "compose(record): $L2"
  has "$L4" "anullsrc" && has "$L4" "clips/4.webm" && has "$L4" "-t 6.500" && pass "compose(無音): anullsrc・-t 6.500（max(seconds 6, 録画 6.0) + gap）" || fail "compose(無音): $L4"
  has "$L5" "-t 2.500" && pass "compose: 最後のカードの -t 2.500" || fail "compose(5): $L5"
  allok=1
  for l in "$L1" "$L2" "$L4" "$L5"; do
    for k in "scale=1920:1080" "fps=30" "yuv420p" "libx264" "aac" "-ar 48000" "-ac 2"; do has "$l" "$k" || { allok=0; echo "  足りない: $k in $l" >&2; }; done
  done
  [ "$allok" = 1 ] && pass "compose: すべてのシーンで出力の形がそろう（1920×1080・30fps・yuv420p・libx264・aac・48kHz・2ch）" || fail "compose: 出力の形がそろっていない"
  sum="$(grep 'build/' "$LOG" | grep -v concat | sed -E 's/.* -t ([0-9.]+) .*/\1/' | awk '{s+=$1} END {printf "%.1f", s}')"
  sc voice.py measure --dir "$D"
  if grep -q "total: ${sum} " "$W/out"; then pass "compose: 各シーンの -t の合計（${sum}）は measure の時間割の合計と同じ（1 か所の計算）"; else fail "compose: -t の合計 ${sum} と measure $(grep total "$W/out")"; fi
  [ ! -e "$D/build/3.mp4" ] && ! grep -q 'cards/3\|clips/3\.' "$LOG" && pass "compose: kind: omit は build に現れない" || fail "compose: omit が入った"
  n1="$(grep -n 'build/1.mp4' "$LOG" | head -n 1 | cut -d: -f1)"; n2="$(grep -n 'build/2-1.mp4' "$LOG" | head -n 1 | cut -d: -f1)"
  n4="$(grep -n 'build/4.mp4' "$LOG" | head -n 1 | cut -d: -f1)"; n5="$(grep -n 'build/5.mp4' "$LOG" | head -n 1 | cut -d: -f1)"
  [ "$n1" -lt "$n2" ] && [ "$n2" -lt "$n4" ] && [ "$n4" -lt "$n5" ] && pass "compose: シーンの順は scenes.json の順（1 → 2-1 → 4 → 5）" || fail "compose: 順序 $n1 $n2 $n4 $n5"
  cat="$(grep ' concat ' "$LOG" | head -n 1)"
  has "$cat" "-safe 0" && has "$cat" "-c copy" && pass "compose: 結合は -f concat -safe 0 ... -c copy" || fail "compose: 結合 $cat"
  [ "$(grep -c "^file '" "$D/build/concat.txt")" = "4" ] && pass "compose: concat.txt に 4 件" || fail "compose: concat.txt $(cat "$D/build/concat.txt")"
  grep -qF "dry'\\''s" "$D/build/concat.txt" && pass "compose: concat.txt の ' は '\\'' にエスケープされる" || fail "compose: concat.txt のエスケープ $(head -n 1 "$D/build/concat.txt")"
  [ -f "$D/release-video.mp4" ] && [ ! -e "$D/build/concat-part.mp4" ] && pass "compose: 出力ができ、一時ファイルは残らない" || fail "compose: 出力"
  [ "$(H get "$D/build/manifest.json" 'd["over"]')" = "False" ] && [ "$(H get "$D/build/manifest.json" 'len(d["sha"]) == 64 and len(d["content"]) == 64')" = "True" ] && pass "compose: build/manifest.json に sha・content・over: false" || fail "compose: manifest $(cat "$D/build/manifest.json")"
  sc scenes.py status --dir "$D"
  stage_line compose | grep -q done && [ "$(last_line "$W/out")" = "next: none" ] && pass "compose: 書いた manifest を status が done と読む（全段 done・next: none）" || fail "compose: status compose=$(stage_line compose) last=$(last_line "$W/out")"
  # AC-17: 合成の後で clips を撮り直して mark → compose が stale
  printf 'retake-2-1' > "$D/clips/2-1.webm"
  sc scenes.py mark --dir "$D" --stage record --id 2-1
  sc scenes.py status --dir "$D"
  stage_line compose | grep -q stale && pass "compose(AC-17): 合成の後に撮り直して mark すると compose が stale" || fail "compose(AC-17): $(stage_line compose)"

  # --- --out と --dry-run
  mk_prereq; rm -f "$FAKE_DIR/ffmpeg.log"
  sc compose.py --dir "$D" --dry-run
  if [ "$rc" -eq 0 ] && [ ! -s "$FAKE_DIR/ffmpeg.log" ] && [ ! -e "$D/build" ] && grep -q 'ffmpeg' "$W/out"; then pass "compose --dry-run: ffmpeg を呼ばず、引数を表示するだけで何も作らない"; else fail "compose --dry-run: rc=${rc} build=$([ -e "$D/build" ] && echo 有 || echo 無)"; fi
  sc compose.py --dir "$D" --out final.mp4
  if [ "$rc" -eq 0 ] && [ -f "$D/final.mp4" ] && [ "$(H get "$D/build/manifest.json" 'd["file"]')" = "final.mp4" ]; then pass "compose --out: 出力名を変えられ、manifest に記録される"; else fail "compose --out rc=${rc}"; fi
  sc scenes.py status --dir "$D"
  stage_line compose | grep -q done && pass "compose --out: status が出力名を manifest から読んで done" || fail "compose --out: status $(stage_line compose)"

  # --- ffmpeg の失敗: exit 3・途中の出力を残さない
  mk_prereq; rm -f "$FAKE_DIR/ffmpeg.log"
  ENVP=(FAKE_FFMPEG_FAIL=concat)
  sc compose.py --dir "$D"
  ENVP=()
  if [ "$rc" -eq 3 ] && [ ! -e "$D/release-video.mp4" ] && [ ! -e "$D/build/concat-part.mp4" ] && [ ! -e "$D/build/manifest.json" ]; then pass "compose: ffmpeg が失敗したら exit 3・途中の出力も manifest も残さない"; else fail "compose: ffmpeg 失敗 rc=${rc} $(ls "$D" "$D/build" 2>&1 | tr '\n' ' ')"; fi
  sc scenes.py status --dir "$D"
  stage_line compose | grep -q done && fail "compose: 失敗なのに done" || pass "compose: 失敗の後 status の compose は done でない"

  # --- 長さの超過（AC-18）
  mk_prereq
  set_out_dur 130.0
  sc compose.py --dir "$D"
  if [ "$rc" -eq 0 ] && grep -q '^over: 10.0$' "$W/out" && [ "$(H get "$D/build/manifest.json" 'd["over"]')" = "True" ]; then pass "compose(AC-18): 出力が max_seconds を超えたら exit 0 で over: 10.0・manifest に over: true"; else fail "compose(AC-18): rc=${rc} $(cat "$W/out") $(cat "$D/build/manifest.json" 2>/dev/null)"; fi
  sc scenes.py status --dir "$D"
  stage_line compose | grep -q over && ! stage_line compose | grep -q done && [ "$(last_line "$W/out")" = "next: compose" ] && pass "compose(AC-18): status の compose は over（done にならない）・next: compose" || fail "compose(AC-18): status $(stage_line compose) last=$(last_line "$W/out")"
  printf '%s' "$FAKE_DURS" > "$FAKE_DIR/durations"

  # --- 実物の ffmpeg・ffprobe で、同じ形にしたシーンを -c copy で結合できる（偽では捕まらない綴りの誤りを見る）
  real_ffmpeg_suite
}

real_ffmpeg_suite() {
  local RF RP
  RF="$(command -v ffmpeg 2>/dev/null)"; RP="$(command -v ffprobe 2>/dev/null)"
  if [ -z "$RF" ] || [ -z "$RP" ] || ! "$RF" -hide_banner -encoders 2>/dev/null | grep -q libx264; then
    skip "compose(実物): ffmpeg・ffprobe・libx264 が無いので実物での結合を確かめていない"
    return
  fi
  local PORT
  PORT="$(start_server vv2 normal)"
  [ -n "$PORT" ] || { fail "compose(実物): 偽のエンジンを起動できない"; return; }
  new_dir
  "$HPY" - "$D/scenes.json" <<'PY'
import json, sys
sc = lambda i, kind, narr, **kw: dict({"id": i, "section": "demo", "kind": kind, "seconds": 1, "screen": "s", "telop": "t", "narr": narr}, **kw)
d = {"version": 1, "title": "t", "max_seconds": 60, "gap_seconds": 0.5, "scenes": [
    sc("1", "card", "あ", card={"lines": ["x"]}),
    sc("2", "record", "い"),
    sc("3", "record", ""),
]}
json.dump(d, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False)
PY
  cp "$VOICE_VV" "$D/voice.json"; H mut "$D/voice.json" 'd["speed"] = 1.0; d["pause_scale"] = 1.0'
  cp "$FIX_SCRIPT" "$D/script.md"
  mkdir -p "$D/clips" "$D/cards"
  # 実物の素材: カードの png、録画に見立てた H.264 の動画（拡張子は webm のまま。ffmpeg は中身で読む）
  "$RF" -v error -y -f lavfi -i color=c=blue:s=1920x1080 -frames:v 1 "$D/cards/1.png"
  "$RF" -v error -y -f lavfi -i color=c=red:s=640x360:d=1 -c:v libx264 -pix_fmt yuv420p -f mp4 "$D/clips/2.webm"
  "$RF" -v error -y -f lavfi -i color=c=green:s=1280x720:d=1 -c:v libx264 -pix_fmt yuv420p -f mp4 "$D/clips/3.webm"
  local R=0
  real() { env PATH="$PATH" "$PY" "$S/$1" "${@:2}" > "$W/out" 2> "$W/err"; rc=$?; }
  real scenes.py table --dir "$D"; real scenes.py approve --dir "$D"
  real voice.py synth --dir "$D" --engine-url "http://127.0.0.1:$PORT"
  [ "$rc" -eq 0 ] || R=1
  real scenes.py mark --dir "$D" --stage record --id 2; [ "$rc" -eq 0 ] || R=1
  real scenes.py mark --dir "$D" --stage record --id 3; [ "$rc" -eq 0 ] || R=1
  real scenes.py mark --dir "$D" --stage cards --id 1; [ "$rc" -eq 0 ] || R=1
  if [ "$R" -ne 0 ]; then fail "compose(実物): 前の段の準備に失敗 $(head -c 200 "$W/err")"; stop_servers; return; fi
  real compose.py --dir "$D"
  if [ "$rc" -ne 0 ]; then fail "compose(実物): ffmpeg での合成に失敗 rc=${rc} $(head -c 300 "$W/err")"; stop_servers; return; fi
  pass "compose(実物): 実際の ffmpeg で card・record・無音の 3 種を同じ形にして結合できた"
  local info
  info="$("$RP" -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$D/release-video.mp4" 2>&1)"
  [ "$info" = "1920,1080" ] && pass "compose(実物): 出力は 1920×1080" || fail "compose(実物): 解像度 $info"
  "$RP" -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$D/release-video.mp4" 2>&1 | grep -q aac && pass "compose(実物): 音声のストリーム（aac）がある" || fail "compose(実物): 音声が無い"
  local dur
  dur="$("$RP" -v error -show_entries format=duration -of default=nw=1:nk=1 "$D/release-video.mp4")"
  if awk -v d="$dur" 'BEGIN {exit !(d > 6.0 && d < 7.0)}'; then pass "compose(実物): 長さ（${dur} 秒）が時間割の合計（2.5 + 2.5 + 1.5 = 6.5）に近い"; else fail "compose(実物): 長さ ${dur}（期待 6.5 前後）"; fi
  stop_servers
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
  suite_voice
  suite_compose
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
