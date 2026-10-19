#!/usr/bin/env bash
# codex-run.sh（/review・/review-plan から Codex の companion を呼ぶラッパー）の挙動テスト。
#
# 守りたいのは「どの経路で終わっても --out を 1 回だけ書く（在る＝終わった）」「companion が
# exit 0 でも parseError や形の不正を成功にしない」「Codex 上では companion を呼ばない」
# 「後から始まった実行の結果を前の実行が上書きしない」。どれも壊れると skill が黙って Codex を省くか、
# 前回の結果を今回のものとして読むだけで、通常の動作確認では気づけない。
#
# 実物の Codex には一切つながない。CODEX_RUN_PLUGIN_ROOT で偽の companion（node で動く .mjs）を
# 差し込む。偽の companion は想定外の引数で exit 2 を返す（寛容な偽物だと、実物が受け付けない
# 呼び方や --model の付け忘れでも全件が通ってしまうため）。HOME は差し替えない（mise の shim が
# 壊れるため）。
#
# 起動: bash shared/scripts/tests/test-codex-run.sh

# set -e は使わない。1 件目の失敗で残りが走らなくなると、Red で全件の失敗を確かめられない
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CR="$REPO_ROOT/shared/scripts/codex-run.sh"
MODEL="gpt-6.1-sol"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass_count=0
fail_count=0

pass() { echo -e "${GREEN}[PASS]${NC} $1"; pass_count=$((pass_count + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; fail_count=$((fail_count + 1)); }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# 実行者の環境で判定が変わらないようにする（Codex 上でテストを回すと全件が「省略」になる）
unset CODEX_THREAD_ID CODEX_SANDBOX
# 既定の運用ログ（~/.local/state/...）を汚さない
export CODEX_RUN_LOG="$WORK/default-runs.jsonl"

NODE_BIN="$(command -v node)"
BASH_BIN="/bin/bash"

# ============================================================ 共通の道具

assert_rc() {  # $1=名前 $2=期待 $3=実際
    if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1（rc=$3、期待 $2）: $(head -c 400 "$CASE/stderr" 2>/dev/null)"; fi
}

assert_eq() {  # $1=名前 $2=期待 $3=実際
    if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1（「${3:0:300}」、期待「$2」）"; fi
}

assert_has() {  # $1=名前 $2=出力 $3=含むべき文字列
    if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1（「$3」が無い）: ${2:0:400}"; fi
}

assert_not_has() {  # $1=名前 $2=出力 $3=含まないはずの文字列
    if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1（「$3」がある）: ${2:0:400}"; fi
}

assert_true() {  # $1=名前 $2=条件の説明（失敗時） 以降=test の式
    local name="$1" why="$2"
    shift 2
    if "$@"; then pass "$name"; else fail "${name}（${why}）"; fi
}

# JSON ファイルの式の値（文字列はそのまま、それ以外は JSON）。読めなければ __PARSE_ERROR__、無ければ __NO_FILE__
jget() {  # $1=ファイル $2=式（o が JSON）
    [[ -f "$1" ]] || { echo "__NO_FILE__"; return; }
    "$NODE_BIN" -e '
        let o;
        try { o = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); }
        catch (e) { console.log("__PARSE_ERROR__"); process.exit(0); }
        const v = eval(process.argv[2]);
        console.log(typeof v === "string" ? v : JSON.stringify(v));
    ' "$1" "$2"
}

# ケースごとの作業場所。偽の companion の記録先と --out をここに置く
new_case() {  # $1=ケース名
    CASE="$WORK/$1"
    mkdir -p "$CASE"
    OUT="$CASE/out.json"
    export FAKE_LOG="$CASE/calls.log" FAKE_DIR="$CASE"
    unset FAKE_MODE FAKE_SETUP
}

# ラッパーを対象リポジトリの中で走らせる。rc は RC に入る
cr() {
    (cd "$TARGET" && "$BASH_BIN" "$CR" "$@") >"$CASE/stdout" 2>"$CASE/stderr"
    RC=$?
}

calls() { cat "$FAKE_LOG" 2>/dev/null; }

# ------------------------------------------------------------ fixture
# 対象リポジトリ（review の -C と運用ログの repo に使う）
TARGET="$WORK/target-repo"
mkdir -p "$TARGET"
git -C "$TARGET" init -q
export FAKE_CWD="$TARGET"

PLAN_FILE="$TARGET/tmp/plan.md"
mkdir -p "$TARGET/tmp"
echo "# 計画" >"$PLAN_FILE"

# 偽の companion。引数は実物（codex-companion.mjs 1.0.6）が受け付ける形のうち、
# ラッパーが渡すと決めた並びだけを通す
PLUGIN="$WORK/plugin"
mkdir -p "$PLUGIN/scripts"
cat >"$PLUGIN/scripts/codex-companion.mjs" <<'EOF'
import fs from "node:fs";

const argv = process.argv.slice(2);
if (process.env.FAKE_LOG) fs.appendFileSync(process.env.FAKE_LOG, argv.join(" ") + "\n");
const MODEL = "gpt-6.1-sol";
const mode = process.env.FAKE_MODE || "ok";
const dir = process.env.FAKE_DIR;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const print = (o) => process.stdout.write(JSON.stringify(o, null, 2) + "\n");
const bad = () => { process.stderr.write("fake: unexpected args: " + argv.join(" ") + "\n"); process.exit(2); };

const findings = [
    { severity: "high", title: "t1", body: "b1", file: "a.sh", line_start: 3, line_end: 4, confidence: 0.9, recommendation: "r1" },
    { severity: "low", title: "t2", body: "b2", file: "b.sh", line_start: 1, line_end: 1, confidence: 0.4, recommendation: "r2" },
];
const result = { verdict: "needs-attention", summary: "s", findings, next_steps: ["n"] };

const sub = argv[0];
if (sub === "setup") {
    if (argv.length !== 2 || argv[1] !== "--json") bad();
    const s = process.env.FAKE_SETUP || "ready";
    if (s === "crash") { process.stderr.write("setup exploded: boom\n"); process.exit(1); }
    if (s === "notready") {
        print({ ready: false, auth: { loggedIn: false, detail: "not authenticated" }, nextSteps: ["Run `!codex login`."] });
    } else {
        print({ ready: true, auth: { loggedIn: true, detail: "logged in" }, nextSteps: [] });
    }
    process.exit(0);
}

if (sub === "adversarial-review") {
    const ok = argv.length >= 9 && argv[1] === "--json" && argv[2] === "--model" && argv[3] === MODEL
        && argv[4] === "--base" && argv[5] && argv[6] === "-C" && argv[7] === process.env.FAKE_CWD
        && argv.slice(8).join(" ").trim() !== "";
    if (!ok) bad();
    const base = { review: "Adversarial Review", target: {}, threadId: "th", context: {}, codex: {}, rawOutput: "", reasoningSummary: null };
    switch (mode) {
        case "ok": print({ ...base, result, parseError: null }); process.exit(0);
        case "slow": await sleep(3000); print({ ...base, result: { ...result, summary: "slow" }, parseError: null }); process.exit(0);
        case "badfinding": print({ ...base, result: { ...result, findings: [{}] }, parseError: null }); process.exit(0);
        case "parseerror": print({ ...base, result: null, parseError: "stream disconnected before completion: boom" }); process.exit(0);
        case "noresult": print({ ...base, parseError: null }); process.exit(0);
        case "fail": process.stderr.write("codex exploded: rate limited\n"); process.exit(1);
        case "special": process.stderr.write('a "q" b\\c\nline2\n'); process.exit(1);
        case "longerr": process.stderr.write("x".repeat(3000) + "\n"); process.exit(1);
        case "badjson": process.stdout.write("{broken\n"); process.exit(0);
        default: bad();
    }
}

if (sub === "task") {
    const ok = argv.length === 8 && argv[1] === "--json" && argv[2] === "--model" && argv[3] === MODEL
        && argv[4] === "--prompt-file" && argv[5] && argv[6] === "-C" && argv[7] === process.env.FAKE_CWD;
    if (!ok) bad();
    fs.copyFileSync(argv[5], dir + "/prompt.txt");
    const base = { threadId: "th", touchedFiles: [], reasoningSummary: null };
    switch (mode) {
        case "plan_ok": print({ ...base, status: 0, rawOutput: "```json\n" + JSON.stringify(result) + "\n```" }); process.exit(0);
        case "plan_notjson": print({ ...base, status: 0, rawOutput: "I could not produce JSON" }); process.exit(0);
        case "plan_badfinding": {
            const bad = { ...result, findings: [{ ...findings[0], severity: "blocker" }] };
            print({ ...base, status: 0, rawOutput: JSON.stringify(bad) }); process.exit(0);
        }
        case "plan_fail": print({ ...base, status: 1, rawOutput: "" }); process.exit(1);
        default: bad();
    }
}

bad();
EOF
export CODEX_RUN_PLUGIN_ROOT="$PLUGIN"

# ============================================================ review の判定

echo "--- review の判定"

new_case T1
cr review --base main --out "$OUT"
assert_rc "T1 review 成功: rc=0" 0 "$RC"
assert_eq "T1 status:ok" ok "$(jget "$OUT" o.status)"
assert_eq "T1 findings の件数" 2 "$(jget "$OUT" o.result.findings.length)"
assert_eq "T1 model" "$MODEL" "$(jget "$OUT" o.model)"
assert_eq "T1 reason は null" null "$(jget "$OUT" o.reason)"
assert_has "T1 argv" "$(calls)" "adversarial-review --json --model $MODEL --base main -C $TARGET"
assert_has "T1 setup を先に呼ぶ" "$(calls | head -1)" "setup --json"

new_case T2
FAKE_MODE=parseerror cr review --base main --out "$OUT"
assert_rc "T2 exit 0 でも parseError なら rc=3" 3 "$RC"
assert_eq "T2 status:unavailable" unavailable "$(jget "$OUT" o.status)"
assert_has "T2 reason に parseError の文言" "$(jget "$OUT" o.reason)" "stream disconnected before completion"

new_case T3
FAKE_MODE=noresult cr review --base main --out "$OUT"
assert_rc "T3 exit 0 で result 無しは rc=3" 3 "$RC"
assert_eq "T3 status:unavailable" unavailable "$(jget "$OUT" o.status)"

new_case T4
FAKE_MODE=fail cr review --base main --out "$OUT"
assert_rc "T4 companion exit 1 は rc=3" 3 "$RC"
assert_has "T4 reason に stderr の文言" "$(jget "$OUT" o.reason)" "codex exploded: rate limited"

new_case T5
FAKE_SETUP=notready cr review --base main --out "$OUT"
assert_rc "T5 未ログインは rc=3" 3 "$RC"
assert_has "T5 reason に auth.detail" "$(jget "$OUT" o.reason)" "not authenticated"
assert_not_has "T5 adversarial-review を呼ばない" "$(calls)" "adversarial-review"

new_case T5b
FAKE_SETUP=crash cr review --base main --out "$OUT"
assert_rc "T5b setup が落ちたら rc=3" 3 "$RC"
assert_has "T5b reason に setup の stderr" "$(jget "$OUT" o.reason)" "setup exploded: boom"

new_case T6a
CODEX_RUN_PLUGIN_ROOT="$WORK/no-such-plugin" cr review --base main --out "$OUT"
assert_rc "T6a plugin のパスが無ければ rc=3" 3 "$RC"
assert_eq "T6a status:unavailable" unavailable "$(jget "$OUT" o.status)"

# installed_plugins.json からの解決（テスト用の上書きを外し、CLAUDE_CONFIG_DIR で差し込む）
new_case T6b
mkdir -p "$CASE/cfg/plugins"
echo '{"version":2,"plugins":{"other@x":[{"scope":"user","installPath":"/nowhere"}]}}' >"$CASE/cfg/plugins/installed_plugins.json"
(unset CODEX_RUN_PLUGIN_ROOT; CLAUDE_CONFIG_DIR="$CASE/cfg" cr review --base main --out "$OUT"; exit "$RC")
RC=$?
assert_rc "T6b installed_plugins.json に該当が無ければ rc=3" 3 "$RC"
assert_eq "T6b companion を呼ばない" "" "$(calls)"

new_case T6c
mkdir -p "$CASE/cfg/plugins"
cat >"$CASE/cfg/plugins/installed_plugins.json" <<EOF
{"version":2,"plugins":{"codex@openai-codex":[
  {"scope":"project","projectPath":"/x","installPath":"/nowhere"},
  {"scope":"user","installPath":"$PLUGIN"}
]}}
EOF
(unset CODEX_RUN_PLUGIN_ROOT; CLAUDE_CONFIG_DIR="$CASE/cfg" cr review --base main --out "$OUT"; exit "$RC")
RC=$?
assert_rc "T6c installed_plugins.json の user の installPath で解決して rc=0" 0 "$RC"

# ============================================================ Codex 上の検知

echo "--- Codex 上の検知"

new_case T7
CODEX_THREAD_ID=x cr review --base main --out "$OUT"
assert_rc "T7 CODEX_THREAD_ID は rc=4" 4 "$RC"
assert_eq "T7 status:skipped" skipped "$(jget "$OUT" o.status)"
assert_eq "T7 companion を呼ばない（setup も）" "" "$(calls)"

new_case T8
CODEX_SANDBOX=seatbelt cr review --base main --out "$OUT"
assert_rc "T8 CODEX_SANDBOX は rc=4" 4 "$RC"
assert_eq "T8 companion を呼ばない" "" "$(calls)"

new_case T9
CODEX_COMPANION_SESSION_ID=x CODEX_COMPANION_TRANSCRIPT_PATH=/x cr review --base main --out "$OUT"
assert_rc "T9 CODEX_COMPANION_* だけなら実行する（前方一致で誤判定しない）" 0 "$RC"

# ============================================================ plan モード

echo "--- plan モード"

new_case T10
FAKE_MODE=plan_ok cr plan --plan tmp/plan.md --out "$OUT"
assert_rc "T10 plan 成功: rc=0" 0 "$RC"
assert_eq "T10 status:ok" ok "$(jget "$OUT" o.status)"
assert_eq "T10 mode" plan "$(jget "$OUT" o.mode)"
assert_eq "T10 囲みの中の JSON を取り出す" needs-attention "$(jget "$OUT" o.result.verdict)"
assert_has "T10 argv" "$(calls)" "task --json --model $MODEL --prompt-file"
assert_not_has "T10 --write を付けない" "$(calls)" "--write"
assert_has "T10 プロンプトに計画ファイルの絶対パス" "$(cat "$CASE/prompt.txt" 2>/dev/null)" "$PLAN_FILE"

new_case T11
FAKE_MODE=plan_notjson cr plan --plan tmp/plan.md --out "$OUT"
assert_rc "T11 rawOutput が JSON でなければ rc=3" 3 "$RC"
assert_eq "T11 status:unavailable" unavailable "$(jget "$OUT" o.status)"
assert_has "T11 生の出力を <out>.raw.txt に残す" "$(cat "$OUT.raw.txt" 2>/dev/null)" "I could not produce JSON"

new_case T12
FAKE_MODE=plan_fail cr plan --plan tmp/plan.md --out "$OUT"
assert_rc "T12 turn の失敗（stderr 空）は rc=3" 3 "$RC"
reason="$(jget "$OUT" o.reason)"
assert_true "T12 reason が空でない" "reason=$reason" test -n "$reason" -a "$reason" != null -a "$reason" != __NO_FILE__

# ============================================================ 引数不正

echo "--- 引数不正"

new_case T14a
cr bogus
assert_rc "T14a 未知のモード（--out 無し）は rc=2" 2 "$RC"

new_case T14b
cr review --base main
assert_rc "T14b --out 無しは rc=2" 2 "$RC"

new_case T14c
cr bogus --out "$OUT"
assert_rc "T14c --out はあるが未知のモードは rc=2" 2 "$RC"
assert_eq "T14c status:usage が書かれる" usage "$(jget "$OUT" o.status)"

new_case T14d
cr review --out "$OUT"
assert_rc "T14d review に --base が無ければ rc=2" 2 "$RC"
assert_eq "T14d status:usage" usage "$(jget "$OUT" o.status)"
assert_eq "T14d companion を呼ばない" "" "$(calls)"

new_case T14e
cr plan --out "$OUT"
assert_rc "T14e plan に --plan が無ければ rc=2" 2 "$RC"
assert_eq "T14e status:usage" usage "$(jget "$OUT" o.status)"

new_case T14f
cr review --base main --out "$OUT" --plan
assert_rc "T14f オプションに値が無ければ rc=2" 2 "$RC"
assert_has "T14f status:usage・reason に欠けたオプション" "$(jget "$OUT" o.status) $(jget "$OUT" o.reason)" "usage --plan に値が無い"

new_case T14g
cr review --base main --bogus --out "$OUT"
assert_rc "T14g 未知の引数は rc=2" 2 "$RC"
assert_has "T14g reason に未知の引数（その後ろの --out も読む）" "$(jget "$OUT" o.reason)" "未知の引数: --bogus"
assert_eq "T14g companion を呼ばない" "" "$(calls)"

new_case T14h
cr plan --plan tmp/no-such-plan.md --out "$OUT"
assert_rc "T14h 計画ファイルが無ければ rc=2" 2 "$RC"
assert_has "T14h reason に計画ファイル" "$(jget "$OUT" o.reason)" "計画ファイルが無い"

new_case T14i
cr wait --out "$OUT" --timeout-sec abc
assert_rc "T14i wait の --timeout-sec が整数でなければ rc=2" 2 "$RC"
assert_true "T14i wait の引数不正では --out を書かない（実行の結果と取り違えない）" "書かれている" test ! -e "$OUT"

# ============================================================ 運用ログ・--out の書き方

echo "--- 運用ログ・--out の書き方"

new_case T15
CODEX_RUN_LOG="$CASE/runs.jsonl" cr review --base main --out "$OUT"
assert_eq "T15 運用ログが 1 行" 1 "$(wc -l <"$CASE/runs.jsonl" 2>/dev/null | tr -d ' ')"
line="$(cat "$CASE/runs.jsonl" 2>/dev/null)"
echo "$line" >"$CASE/line.json"
assert_eq "T15 mode" review "$(jget "$CASE/line.json" o.mode)"
assert_eq "T15 status" ok "$(jget "$CASE/line.json" o.status)"
assert_eq "T15 findings" 2 "$(jget "$CASE/line.json" o.findings)"
assert_eq "T15 repo" target-repo "$(jget "$CASE/line.json" o.repo)"
assert_eq "T15 elapsed_sec は数値" number "$(jget "$CASE/line.json" 'typeof o.elapsed_sec')"

new_case T15b
# worktree から実行しても、運用ログの repo はリポジトリの名前（worktree のディレクトリ名ではない）
git -C "$TARGET" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$TARGET" worktree add -q "$CASE/wt-dir" 2>/dev/null
(cd "$CASE/wt-dir" && CODEX_RUN_LOG="$CASE/runs.jsonl" FAKE_CWD="$CASE/wt-dir" "$BASH_BIN" "$CR" review --base main --out "$OUT") >/dev/null 2>&1
cat "$CASE/runs.jsonl" >"$CASE/line.json" 2>/dev/null
assert_eq "T15b worktree でも repo はリポジトリの名前" target-repo "$(jget "$CASE/line.json" o.repo)"

new_case T16
echo "file" >"$CASE/blocker"
CODEX_RUN_LOG="$CASE/blocker/runs.jsonl" cr review --base main --out "$OUT"
assert_rc "T16 ログが書けなくても rc は変わらない" 0 "$RC"
assert_eq "T16 --out も変わらない" ok "$(jget "$OUT" o.status)"

new_case T17
cr review --base main --out "$CASE/new/dir/out.json"
assert_rc "T17 --out の親ディレクトリが無くても rc=0" 0 "$RC"
assert_eq "T17 作って書く" ok "$(jget "$CASE/new/dir/out.json" o.status)"

new_case T18
echo '{"status":"ok","result":{"findings":[]}}' >"$OUT"
echo "old raw" >"$OUT.raw.txt"
FAKE_SETUP=notready cr review --base main --out "$OUT"
assert_eq "T18 前回の --out は今回の結果に置き換わる" unavailable "$(jget "$OUT" o.status)"
assert_true "T18 前回の <out>.raw.txt は消える" "残っている" test ! -e "$OUT.raw.txt"

new_case T19
(cd "$TARGET" && FAKE_MODE=slow "$BASH_BIN" "$CR" review --base main --out "$OUT") >/dev/null 2>&1 &
bg=$!
sleep 1
if [[ -e "$OUT" ]]; then during=exists; else during=absent; fi
wait "$bg"
assert_eq "T19 実行中は --out が無い" absent "$during"
assert_eq "T19 終了後は --out が在る" ok "$(jget "$OUT" o.status)"

new_case T20
FAKE_MODE=badjson cr review --base main --out "$OUT"
assert_rc "T20 壊れた JSON（想定外の失敗）は rc=3" 3 "$RC"
assert_eq "T20 --out に status:unavailable" unavailable "$(jget "$OUT" o.status)"

new_case T27
# 前回の遅い実行（A）が終わる前に今回の実行（B）が始まり、B が先に終わる
(cd "$TARGET" && FAKE_MODE=slow CODEX_RUN_LOG="$CASE/runs.jsonl" "$BASH_BIN" "$CR" review --base main --out "$OUT") >/dev/null 2>&1 &
bg=$!
sleep 1
cr review --base main --out "$OUT"
assert_eq "T27 後の実行の結果が --out に在る" s "$(jget "$OUT" o.result.summary)"
wait "$bg"
assert_has "T27 前の実行は運用ログに superseded と残る" "$(cat "$CASE/runs.jsonl" 2>/dev/null)" '"status":"superseded"'
assert_eq "T27 前の遅い実行は、後から終わっても --out を上書きしない" s "$(jget "$OUT" o.result.summary)"
assert_eq "T27 持ち主の印は後の実行のまま" "$(jget "$OUT" o.run)" "$(cat "$OUT.owner" 2>/dev/null)"

new_case T27b
# 持ち主の確認の後に後の実行が始まり、前の実行が --out を置いた（確認と mv の間の窓）
echo "later-run" >"$OUT.owner"
echo '{"status":"ok","run":"earlier-run","mode":"review","model":"m","elapsed_sec":1,"reason":null,"result":null}' >"$OUT"
start=$(date +%s)
cr wait --out "$OUT" --timeout-sec 2
assert_rc "T27b run が持ち主と違う --out は「現れた」とみなさない" 3 "$RC"
echo '{"status":"ok","run":"later-run","mode":"review","model":"m","elapsed_sec":1,"reason":null,"result":null}' >"$OUT"
cr wait --out "$OUT" --timeout-sec 2
assert_rc "T27b run が持ち主と一致すれば戻る" 0 "$RC"

new_case T28
FAKE_MODE=badfinding cr review --base main --out "$OUT"
assert_rc "T28 findings の要素が不正なら rc=3" 3 "$RC"
assert_eq "T28 status:unavailable" unavailable "$(jget "$OUT" o.status)"
assert_has "T28 生の出力を <out>.raw.txt に残す" "$(cat "$OUT.raw.txt" 2>/dev/null)" '"findings"'

new_case T28b
FAKE_MODE=plan_badfinding cr plan --plan tmp/plan.md --out "$OUT"
assert_rc "T28b plan で severity が想定外なら rc=3" 3 "$RC"
assert_has "T28b 生の出力を <out>.raw.txt に残す" "$(cat "$OUT.raw.txt" 2>/dev/null)" "blocker"

# ============================================================ wait

echo "--- wait"

new_case T21
echo '{"status":"ok","mode":"review","model":"m","elapsed_sec":1,"reason":null,"result":null}' >"$OUT"
start=$(date +%s)
cr wait --out "$OUT"
elapsed=$(($(date +%s) - start))
assert_rc "T21 --out が在れば rc=0" 0 "$RC"
assert_eq "T21 stdout に status" ok "$(cat "$CASE/stdout")"
assert_true "T21 所要が 2 秒未満" "elapsed=${elapsed}" test "$elapsed" -lt 2
assert_eq "T21 wait は companion を呼ばない" "" "$(calls)"

new_case T22
start=$(date +%s)
cr wait --out "$OUT" --timeout-sec 2
elapsed=$(($(date +%s) - start))
assert_rc "T22 現れなければ rc=3" 3 "$RC"
assert_true "T22 所要が 2〜6 秒" "elapsed=${elapsed}" test "$elapsed" -ge 2 -a "$elapsed" -le 6

new_case T23
(cd "$TARGET" && FAKE_MODE=slow "$BASH_BIN" "$CR" review --base main --out "$OUT") >/dev/null 2>&1 &
bg=$!
start=$(date +%s)
cr wait --out "$OUT" --timeout-sec 20
elapsed=$(($(date +%s) - start))
wait "$bg"
assert_rc "T23 実行の完了を待って rc=0" 0 "$RC"
assert_eq "T23 stdout に status" ok "$(cat "$CASE/stdout")"
assert_true "T23 現れた時点で戻る（10 秒未満）" "elapsed=${elapsed}" test "$elapsed" -lt 10

new_case T23b
cr wait --timeout-sec 2
assert_rc "T23b wait に --out が無ければ rc=2" 2 "$RC"

# ============================================================ node 不在・エスケープ

echo "--- node 不在・エスケープ"

if PATH=/usr/bin:/bin command -v node >/dev/null 2>&1; then
    fail "T24/T25 の前提: PATH=/usr/bin:/bin でも node が見える（$(PATH=/usr/bin:/bin command -v node)）"
else
    new_case T24
    PATH=/usr/bin:/bin cr review --base main --out "$OUT"
    assert_rc "T24 node 不在は rc=3" 3 "$RC"
    assert_eq "T24 status:unavailable" unavailable "$(jget "$OUT" o.status)"
    assert_has "T24 reason に node" "$(jget "$OUT" o.reason)" "node"

    new_case T25
    CODEX_THREAD_ID=x PATH=/usr/bin:/bin cr review --base main --out "$OUT"
    assert_rc "T25 Codex 上かつ node 不在は rc=4" 4 "$RC"
    assert_eq "T25 status:skipped" skipped "$(jget "$OUT" o.status)"
fi

new_case T26
FAKE_MODE=special cr review --base main --out "$OUT"
assert_rc "T26 rc=3" 3 "$RC"
expected="$(printf 'a "q" b\\c\nline2')"
assert_eq "T26 \"・\\・改行を含む reason が JSON として読めて元の文字列と一致" "$expected" "$(jget "$OUT" o.reason)"

new_case T26b
FAKE_MODE=longerr cr review --base main --out "$OUT"
assert_eq "T26b reason は 2000 文字で切る" 2000 "$(jget "$OUT" o.reason.length)"

# ============================================================ 結果

echo ""
echo "PASS: $pass_count / FAIL: $fail_count"
[[ "$fail_count" -eq 0 ]]
