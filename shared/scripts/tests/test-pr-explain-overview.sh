#!/usr/bin/env bash
# pr-explain の図解の流し込みスクリプト（shared/skills/pr-explain/scripts/render_overview.py）の挙動テスト。
#
# 図解のデータには他人の PR の文字列（タイトル・識別子・差分の引用）が入る。HTML パーサーは
# JSON の文字列の中でも `</script>` で script 要素を閉じるので、埋め込みのエスケープが漏れると
# 図解を開いた時にスクリプトが動く。壊れても図解は「それらしく」表示されるため、通常の
# 動作確認では気づけない。不正なデータ（列の範囲外・不明な kind 等）も、検証が漏れると
# 描画が無言で崩れる。
#
# スクリプトは /usr/bin/python3（3.9）でも動かす前提なので、python3 と /usr/bin/python3 が
# 別物なら両方で全件を回す。雛形の描画 script の構文は node があれば `node --check` で見る。
#
# 起動: bash shared/scripts/tests/test-pr-explain-overview.sh

# set -e は使わない。1 件目の失敗で残りが走らなくなると、Red で全件の失敗を確かめられない
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RENDER="$REPO_ROOT/shared/skills/pr-explain/scripts/render_overview.py"
TEMPLATE="$REPO_ROOT/shared/skills/pr-explain/reference/overview-template.html"

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

# 出力 HTML から data の script 要素の本文を取り出す・データを組み立てる補助。
# テスト側の python は系統を固定する（被検の python を替えても補助の挙動は変えない）
HELPER="$BASE/helper.py"
cat > "$HELPER" <<'PY'
import json, re, sys

OPEN = '<script type="application/json" id="data">'

def body_of(path):
    s = open(path, encoding="utf-8").read()
    i = s.index(OPEN) + len(OPEN)
    j = s.index("</script>", i)
    return s[i:j]

cmd = sys.argv[1]
if cmd == "default":
    # 雛形の既定のデータを取り出して書き出す
    json.dump(json.loads(body_of(sys.argv[2])), open(sys.argv[3], "w", encoding="utf-8"), ensure_ascii=False)
elif cmd == "mutate":
    # 既定のデータに python の文を当てる（d が辞書）
    d = json.load(open(sys.argv[2], encoding="utf-8"))
    exec(sys.argv[4], {"d": d})
    json.dump(d, open(sys.argv[3], "w", encoding="utf-8"), ensure_ascii=False)
elif cmd == "evil":
    # title と flow に、script 要素を閉じる列・コメントの開始・行区切り文字を入れる
    d = json.load(open(sys.argv[2], encoding="utf-8"))
    t = "</script><script>alert(1)</script><!-- a>b&c" + chr(0x2028) + "x" + chr(0x2029) + "y"
    d["title"] = t
    d["flow"].append(t)
    json.dump(d, open(sys.argv[3], "w", encoding="utf-8"), ensure_ascii=False)
    open(sys.argv[4], "w", encoding="utf-8").write(t)
elif cmd == "body":
    sys.stdout.write(body_of(sys.argv[2]))
elif cmd == "roundtrip":
    # 本文に生の < と U+2028・U+2029 が無く、json.loads で元の title に戻るか
    b = body_of(sys.argv[2])
    want = open(sys.argv[3], encoding="utf-8").read()
    # JSON の構文には < > & が出てこないので、本文に生で残っていればエスケープ漏れ
    bad = [c for c in ("<", ">", "&", chr(0x2028), chr(0x2029)) if c in b]
    got = json.loads(b)["title"]
    if bad:
        print("raw:" + ",".join(repr(c) for c in bad)); sys.exit(1)
    if got != want:
        print("mismatch:" + repr(got)); sys.exit(1)
elif cmd == "outside":
    # data の本文を除いた部分が雛形と同じか
    def strip(p):
        s = open(p, encoding="utf-8").read()
        i = s.index(OPEN) + len(OPEN)
        j = s.index("</script>", i)
        return s[:i] + s[j:]
    sys.exit(0 if strip(sys.argv[2]) == strip(sys.argv[3]) else 1)
elif cmd == "scripts":
    # 雛形の実行される script（type 属性の無いもの）を書き出す
    # HTML コメントの中の「<script>」という文言を要素と取り違えないよう、先にコメントを除く
    s = re.sub(r"<!--.*?-->", "", open(sys.argv[2], encoding="utf-8").read(), flags=re.S)
    for k, m in enumerate(re.findall(r"<script>(.*?)</script>", s, re.S)):
        open("%s.%d.js" % (sys.argv[3], k), "w", encoding="utf-8").write(m)
PY
HPY=/usr/bin/python3

run_suite() {
  local PY="$1"
  local W="$BASE/$(basename "$PY")-$RANDOM"
  mkdir -p "$W"
  LABEL="[$PY] "
  local DEF="$W/default.json"
  "$HPY" "$HELPER" default "$TEMPLATE" "$DEF" || { fail "雛形から既定のデータを取り出せない"; return; }

  # --- C-4: 既定のデータで成功し、data の本文だけが差し替わる
  "$PY" "$RENDER" --data "$DEF" --out "$W/ok.html" > "$W/ok.out" 2> "$W/ok.err"
  rc=$?
  if [ "$rc" -eq 0 ] && [ -f "$W/ok.html" ]; then pass "既定のデータで exit 0"; else fail "既定のデータで exit 0 にならない（rc=$rc: $(head -n 1 "$W/ok.err")）"; fi
  if [ -f "$W/ok.html" ] && "$HPY" "$HELPER" outside "$W/ok.html" "$TEMPLATE"; then pass "data の本文以外は雛形と同じ"; else fail "data の本文以外が雛形と違う（描画コードが壊れた）"; fi

  # --- C-1・C-2: 埋め込みのエスケープ（regression: </script> による脱出）
  # 悪意のある文字列は python で作る（bash 3.2 の $'...' は \u を解さない）
  "$HPY" "$HELPER" evil "$DEF" "$W/evil.json" "$W/evil.title"
  "$PY" "$RENDER" --data "$W/evil.json" --out "$W/evil.html" > /dev/null 2> "$W/evil.err"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    msg=$("$HPY" "$HELPER" roundtrip "$W/evil.html" "$W/evil.title")
    if [ $? -eq 0 ]; then pass "regression: </script>・<!--・U+2028 を含むデータでも本文に生の < > & が無く、元の文字列に戻る"; else fail "regression: 埋め込みのエスケープが漏れている（${msg}）"; fi
    n=$(grep -c '<script' "$W/evil.html")
    if [ "$n" -eq "$(grep -c '<script' "$TEMPLATE")" ]; then pass "script 要素が増えていない"; else fail "script 要素の数が変わった（${n}）"; fi
  else
    fail "regression: 悪意のある文字列を含むデータで失敗した（rc=$rc: $(head -n 1 "$W/evil.err")）"
  fi

  # --- C-3: 不正なデータは exit 非 0 と、どこが悪いかの 1 行
  bad_case() {
    local name="$1" stmt="$2" want="$3"
    "$HPY" "$HELPER" mutate "$DEF" "$W/bad.json" "$stmt" || { fail "$name: データを作れない"; return; }
    rm -f "$W/bad.html"
    "$PY" "$RENDER" --data "$W/bad.json" --out "$W/bad.html" > /dev/null 2> "$W/bad.err"
    local rc=$?
    if [ "$rc" -ne 0 ] && grep -qF -- "$want" "$W/bad.err" && [ ! -e "$W/bad.html" ]; then
      pass "$name: exit 非 0・メッセージに ${want}・出力なし"
    else
      fail "$name: rc=${rc}、stderr=$(head -n 1 "$W/bad.err")（期待: ${want}）"
    fi
  }
  bad_case "col が範囲外" 'd["graph"]["nodes"][1]["col"] = len(d["graph"]["columns"])' 'graph.nodes[1].col'
  bad_case "col が負" 'd["graph"]["nodes"][0]["col"] = -1' 'graph.nodes[0].col'
  bad_case "edges の id が nodes に無い" 'd["graph"]["edges"][0][1] = "zz"' 'graph.edges[0]'
  bad_case "nodes の kind が許可外" 'd["graph"]["nodes"][0]["kind"] = "gen"' 'graph.nodes[0].kind'
  bad_case "method の kind が許可外" 'd["method"][0]["kind"] = "nw"' 'method[0].kind'
  bad_case "files の kind が許可外" 'd["files"][0]["kind"] = "x"' 'files[0].kind'
  bad_case "added が文字列" 'd["files"][0]["added"] = "1,200"' 'files[0].added'
  bad_case "added が負" 'd["files"][0]["added"] = -1' 'files[0].added'
  bad_case "added が真偽値" 'd["files"][0]["added"] = True' 'files[0].added'
  bad_case "必須キーが無い" 'del d["pins"]' 'pins'
  bad_case "graph.columns が空" 'd["graph"]["columns"] = []; d["graph"]["nodes"] = []; d["graph"]["edges"] = []' 'graph.columns'
  bad_case "pins の n が整数でない" 'd["pins"][0]["n"] = "1"' 'pins[0].n'
  bad_case "pin が整数でも整数の配列でもない" 'd["graph"]["nodes"][1]["pin"] = [1, "2"]' 'graph.nodes[1].pin'
  bad_case "title の型が違う" 'd["title"] = 1' 'title'
  bad_case "flow の要素が文字列でない" 'd["flow"][1] = 2' 'flow[1]'
  bad_case "nodes の id が重複" 'd["graph"]["nodes"][1]["id"] = d["graph"]["nodes"][0]["id"]' 'graph.nodes[1].id'
  bad_case "nodes の note が文字列でない" 'd["graph"]["nodes"][0]["note"] = 3' 'graph.nodes[0].note'
  bad_case "edges の形が違う" 'd["graph"]["edges"][0] = ["a"]' '文字列の配列でない'
  # 要素ごとの必須の文字列（描画が文字列として読むもの）
  bad_case "purpose の body が無い" 'del d["purpose"][0]["body"]' 'purpose[0].body'
  bad_case "method の title が文字列でない" 'd["method"][0]["title"] = 1' 'method[0].title'
  bad_case "nodes の label が無い" 'del d["graph"]["nodes"][0]["label"]' 'graph.nodes[0].label'
  bad_case "pins の question が無い" 'del d["pins"][0]["question"]' 'pins[0].question'
  bad_case "files の what が文字列でない" 'd["files"][0]["what"] = None' 'files[0].what'
  printf '[1, 2]' > "$W/notobj.json"
  rm -f "$W/bad.html"
  "$PY" "$RENDER" --data "$W/notobj.json" --out "$W/bad.html" > /dev/null 2> "$W/bad.err"
  rc=$?
  if [ "$rc" -eq 1 ] && grep -q '最上位' "$W/bad.err" && [ ! -e "$W/bad.html" ]; then pass "最上位がオブジェクトでないデータで exit 1・出力なし"; else fail "最上位がオブジェクトでない: rc=${rc}、stderr=$(head -n 1 "$W/bad.err")"; fi
  # 読めない・書けないときも traceback ではなく 1 行で exit 1
  "$PY" "$RENDER" --data "$W/no-such.json" --out "$W/bad.html" > /dev/null 2> "$W/bad.err"
  rc=$?
  if [ "$rc" -eq 1 ] && [ "$(grep -c . "$W/bad.err")" -eq 1 ] && grep -q '^error:' "$W/bad.err"; then pass "データが読めないとき 1 行で exit 1"; else fail "データが読めない: rc=${rc}、stderr=$(head -n 1 "$W/bad.err")"; fi
  "$PY" "$RENDER" --data "$DEF" --out "$W/no-such-dir/out.html" > /dev/null 2> "$W/bad.err"
  rc=$?
  if [ "$rc" -eq 1 ] && [ "$(grep -c . "$W/bad.err")" -eq 1 ] && grep -q '^error:' "$W/bad.err"; then pass "出力先に書けないとき 1 行で exit 1"; else fail "出力先に書けない: rc=${rc}、stderr=$(head -n 1 "$W/bad.err")"; fi
  printf '{"title": "a",}' > "$W/syntax.json"
  rm -f "$W/bad.html"
  "$PY" "$RENDER" --data "$W/syntax.json" --out "$W/bad.html" > /dev/null 2> "$W/bad.err"
  rc=$?
  if [ "$rc" -ne 0 ] && grep -q 'JSON' "$W/bad.err" && [ ! -e "$W/bad.html" ]; then pass "JSON の構文エラーで exit 非 0・出力なし"; else fail "JSON の構文エラー: rc=${rc}、stderr=$(head -n 1 "$W/bad.err")"; fi

  # 空の nodes・edges は通す（列だけの図）
  "$HPY" "$HELPER" mutate "$DEF" "$W/empty.json" 'd["graph"]["nodes"] = []; d["graph"]["edges"] = []'
  "$PY" "$RENDER" --data "$W/empty.json" --out "$W/empty.html" > /dev/null 2> "$W/empty.err"
  rc=$?
  if [ "$rc" -eq 0 ]; then pass "空の nodes・edges は通す"; else fail "空の nodes・edges を拒否した（$(head -n 1 "$W/empty.err")）"; fi
  # pin は整数の配列も通す
  "$HPY" "$HELPER" mutate "$DEF" "$W/pins.json" 'd["graph"]["nodes"][1]["pin"] = [1, 2]'
  "$PY" "$RENDER" --data "$W/pins.json" --out "$W/pins.html" > /dev/null 2> "$W/pins.err"
  rc=$?
  if [ "$rc" -eq 0 ]; then pass "pin の整数の配列は通す"; else fail "pin の整数の配列を拒否した（$(head -n 1 "$W/pins.err")）"; fi

  # --- C-5: 目印が 1 つでない雛形では、既存の出力に触れずに止まる
  for n in 0 2 9; do
    "$HPY" - "$TEMPLATE" "$W/tpl$n.html" "$n" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
OPEN = '<script type="application/json" id="data">'
n = int(sys.argv[3])
if n == 0:
    s = s.replace(OPEN, '<script type="application/json" id="dat">')
elif n == 9:
    # 目印は 1 つだが、その後に </script> が無い
    s = s[:s.index(OPEN) + len(OPEN)] + "{}"
else:
    s = s.replace("</body>", OPEN + "{}</script>\n</body>")
open(sys.argv[2], "w", encoding="utf-8").write(s)
PY
    printf 'keep' > "$W/exist.html"
    "$PY" "$RENDER" --data "$DEF" --out "$W/exist.html" --template "$W/tpl$n.html" > /dev/null 2> "$W/tpl.err"
    rc=$?
    case "$n" in 9) want='閉じていない' ;; *) want='目印' ;; esac
    if [ "$rc" -eq 1 ] && [ "$(cat "$W/exist.html")" = "keep" ] && [ "$(grep -c . "$W/tpl.err")" -eq 1 ] && grep -q '^error:' "$W/tpl.err" && grep -qF -- "$want" "$W/tpl.err"; then pass "雛形の不備（${n}: 0・2 は目印の個数、9 は閉じていない）で 1 行の error（${want}）・exit 1・既存の出力は不変"; else fail "雛形の不備 ${n}: rc=${rc}、出力=$(head -c 20 "$W/exist.html")、stderr=$(head -n 1 "$W/tpl.err")"; fi
  done
}

if [ ! -f "$RENDER" ]; then
  echo "test-pr-explain-overview.sh: 検査対象が見つからない: $RENDER" >&2
  fail "render_overview.py が無い"
else
  # --- C-6: ソースに置換先の 6 文字の列が実在する（書き出し時の解釈で恒等置換になる事故の補助の検出）
  LABEL=""
  if grep -q 'u003c' "$RENDER"; then pass "ソースに u003c の列がある"; else fail "ソースに u003c の列が無い（恒等置換の疑い）"; fi

  # --- C-7: python3 と /usr/bin/python3 の両方で回す
  PY1="$(command -v python3)"
  run_suite "$PY1"
  if [ -x /usr/bin/python3 ] && [ "$(readlink -f "$PY1" 2>/dev/null || echo "$PY1")" != "$(readlink -f /usr/bin/python3 2>/dev/null || echo /usr/bin/python3)" ]; then
    run_suite /usr/bin/python3
  fi
fi

# --- C-8: 雛形の描画 script の構文
LABEL=""
if command -v node >/dev/null 2>&1 && node --version >/dev/null 2>&1; then
  "$HPY" "$HELPER" scripts "$TEMPLATE" "$BASE/tpl"
  found=0
  for js in "$BASE"/tpl.*.js; do
    [ -f "$js" ] || continue
    found=1
    if err=$(node --check "$js" 2>&1); then pass "雛形の描画 script の構文（$(basename "$js")）"; else fail "雛形の描画 script の構文エラー: $(echo "$err" | head -n 3 | tr '\n' ' ')"; fi
  done
  [ "$found" -eq 1 ] || fail "雛形に描画 script が見つからない"
else
  skip "node が無いので雛形の描画 script の構文を確かめていない"
fi

echo
echo "pass: $pass_count / fail: $fail_count / skip: $skip_count"
[ "$fail_count" -eq 0 ]
