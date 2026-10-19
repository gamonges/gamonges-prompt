#!/usr/bin/env bash
# /review・/review-plan から Codex plugin の companion を呼ぶラッパー。
#
#   codex-run.sh review --base <ref> --out <file>      # 差分のレビュー（skill はバックグラウンドで起動）
#   codex-run.sh plan   --plan <file> --out <file>     # 計画のレビュー（同上）
#   codex-run.sh wait   --out <file> [--timeout-sec N] # --out が現れるまで待つ（skill は前景で呼ぶ）
#
# 実行の終了コード: 0 成功 / 3 未実施 / 4 省略（実行者が Codex）/ 2 引数不正。
# --out はどの終了でも、終わる時に 1 回だけ mv で置く。skill は「--out が在る＝実行が終わった」を
# 前提に wait で待ち、分岐は exit code ではなく --out の status で行う（バックグラウンドの exit code は
# 待ち合わせの時点で手元にあるとは限らないため）。
#
# 実行には時間切れを設けない。companion の turn は detached な broker 配下の app-server で走り
# （plugin 1.0.6 の lib/app-server.mjs・lib/broker-lifecycle.mjs）、ラッパーを止めても turn は
# 止まらないため。待ちの上限は wait の側（skill）だけが持つ。
#
# 呼び出し元: shared/skills/review/reference/codex-reviewer.md
# テスト: bash shared/scripts/tests/test-codex-run.sh

set -euo pipefail

MODEL="gpt-6.1-sol"
# 前景の Bash の上限（600 秒）より前に戻る値
DEFAULT_WAIT_SEC=570

START=$(date +%s)
# 実行の識別子。--out と <out>.owner に書き、wait が今回の実行の結果かを照合する
RUN_ID="$$-$START"
SUB=""
OUT=""
BASE_REF=""
PLAN=""
WAIT_SEC="$DEFAULT_WAIT_SEC"
STATUS=""
REASON=""
FINDINGS="null"
RESULT_FILE=""
WORKDIR=""
OWNER=""

# 文字列を JSON の文字列リテラルにする。finish は node を使わずに --out を書く
# （node が無い経路・node より前で抜ける経路でも「在る＝終わった」を守るため）
json_str() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    s="$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')"
    printf '"%s"' "$s"
}

json_str_or_null() {
    if [[ -n "$1" ]]; then json_str "$1"; else printf 'null'; fi
}

write_log() {  # $1=elapsed
    local log="${CODEX_RUN_LOG:-$HOME/.local/state/codex-run/runs.jsonl}"
    local common repo line
    # worktree でもリポジトリ単位で集計できるよう、作業ツリーではなく共通の .git の親の名前を使う
    common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [[ "$common" == */.git ]]; then
        repo="$(basename "$(dirname "$common")")"
    else
        repo="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")")"
    fi
    line="$(printf '{"ts":%s,"mode":%s,"repo":%s,"model":%s,"status":%s,"reason":%s,"elapsed_sec":%d,"findings":%s}' \
        "$(json_str "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" "$(json_str_or_null "$SUB")" "$(json_str "$repo")" \
        "$(json_str "$MODEL")" "$(json_str "$STATUS")" "$(json_str_or_null "$REASON")" "$1" "$FINDINGS")"
    # 1 回の >> で 1 行を書く（同時に 2 本走っても行が混ざらない）
    { mkdir -p "$(dirname "$log")" && printf '%s\n' "$line" >>"$log"; } 2>/dev/null
}

finish() {
    local rc=$?
    trap - EXIT
    set +e
    if [[ -z "$STATUS" ]]; then
        STATUS="unavailable"
        REASON="想定外の失敗（rc=${rc}）"
        rc=3
    fi
    local elapsed=$(($(date +%s) - START))
    # 後から始まった実行が持ち主になっていたら、--out を書かない。時間切れが無いので、前回の遅い
    # 実行が今回の実行の後で終わりうる。この確認と mv の間に後の実行が始まる窓は残るので、
    # 最終的な照合は wait が --out の run と <out>.owner を比べて行う（.owner は消さない）
    if [[ -n "$OWNER" && "$(cat "$OWNER" 2>/dev/null)" != "$RUN_ID" ]]; then
        STATUS="superseded"
        OUT=""
    fi
    if [[ -n "$OUT" ]]; then
        local result="null"
        if [[ "$STATUS" == "ok" && -s "$RESULT_FILE" ]]; then result="$(cat "$RESULT_FILE")"; fi
        mkdir -p "$(dirname "$OUT")" 2>/dev/null
        [[ -n "$WORKDIR" && -f "$WORKDIR/raw.txt" ]] && mv -f "$WORKDIR/raw.txt" "$OUT.raw.txt"
        # tmp に書いてから mv する。途中まで書かれた --out を wait が「終わった」と読まないため
        printf '{"status":%s,"run":%s,"mode":%s,"model":%s,"elapsed_sec":%d,"reason":%s,"result":%s}\n' \
            "$(json_str "$STATUS")" "$(json_str "$RUN_ID")" "$(json_str_or_null "$SUB")" "$(json_str "$MODEL")" "$elapsed" \
            "$(json_str_or_null "$REASON")" "$result" >"$OUT.tmp.$$" && mv -f "$OUT.tmp.$$" "$OUT"
    fi
    # 運用ログの失敗で rc と --out を変えない
    write_log "$elapsed" || true
    [[ -n "$WORKDIR" ]] && rm -rf "$WORKDIR"
    exit "$rc"
}

unavailable() {  # $1=理由
    STATUS="unavailable"
    REASON="$1"
    exit 3
}

# ------------------------------------------------------------ 引数

SUB="${1:-}"
[[ $# -gt 0 ]] && shift
bad=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out | --base | --plan | --timeout-sec)
            if [[ $# -lt 2 ]]; then bad="$1 に値が無い"; break; fi
            case "$1" in
                --out) OUT="$2" ;;
                --base) BASE_REF="$2" ;;
                --plan) PLAN="$2" ;;
                --timeout-sec) WAIT_SEC="$2" ;;
            esac
            shift 2
            ;;
        *)
            # --out を読み取れるよう、不正があっても最後まで読む
            bad="未知の引数: $1"
            shift
            ;;
    esac
done

case "$SUB" in
    review) [[ -n "$BASE_REF" ]] || bad="${bad:-review には --base が要る}" ;;
    plan)
        if [[ -z "$PLAN" ]]; then
            bad="${bad:-plan には --plan が要る}"
        elif [[ ! -f "$PLAN" ]]; then
            bad="${bad:-計画ファイルが無い: ${PLAN}}"
        fi
        ;;
    wait) [[ "$WAIT_SEC" =~ ^[0-9]+$ ]] || bad="${bad:---timeout-sec は整数}" ;;
    *) bad="${bad:-未知のモード: ${SUB:-（なし）}}" ;;
esac
[[ -n "$OUT" ]] || bad="${bad:---out が要る}"

if [[ -n "$bad" ]]; then
    echo "codex-run.sh: ${bad}" >&2
    echo "usage: codex-run.sh review --base <ref> --out <file> | plan --plan <file> --out <file> | wait --out <file> [--timeout-sec N]" >&2
    if [[ -n "$OUT" && "$SUB" != "wait" ]]; then
        trap finish EXIT
        STATUS="usage"
        REASON="$bad"
    fi
    exit 2
fi

# ------------------------------------------------------------ wait

# companion を呼ばず、--out を消さず、運用ログも書かない
if [[ "$SUB" == "wait" ]]; then
    deadline=$(($(date +%s) + WAIT_SEC))
    while :; do
        # .owner があれば、その実行の結果（run が一致する --out）だけを「現れた」とみなす。
        # 前回の遅い実行が、持ち主の確認の直後に --out を置いた場合を読まないため
        if [[ -e "$OUT" ]]; then
            owner="$(cat "$OUT.owner" 2>/dev/null || true)"
            run="$(sed -n 's/^{"status":"[a-z]*","run":"\([^"]*\)".*/\1/p' "$OUT" | head -1)"
            if [[ -z "$owner" || "$run" == "$owner" ]]; then
                sed -n 's/^{"status":"\([a-z]*\)".*/\1/p' "$OUT" | head -1
                exit 0
            fi
        fi
        if [[ $(date +%s) -ge $deadline ]]; then
            echo "codex-run.sh: ${WAIT_SEC} 秒待っても --out が現れない" >&2
            exit 3
        fi
        sleep 1
    done
fi

# ------------------------------------------------------------ 実行

trap finish EXIT
mkdir -p "$(dirname "$OUT")"
# 前回の結果を今回のものとして読ませない
rm -f "$OUT" "$OUT.raw.txt"
OWNER="$OUT.owner"
printf '%s\n' "$RUN_ID" >"$OWNER"

# 完全一致で見る。Claude Code 側にも CODEX_COMPANION_* が入っているので、前方一致だと誤判定する
if [[ -n "${CODEX_THREAD_ID:-}" ]]; then
    STATUS="skipped"; REASON="実行者が Codex（CODEX_THREAD_ID）"; exit 4
fi
if [[ -n "${CODEX_SANDBOX:-}" ]]; then
    STATUS="skipped"; REASON="実行者が Codex（CODEX_SANDBOX）"; exit 4
fi

# installed_plugins.json を読むのにも要るので、plugin の解決より先に見る
NODE="$(command -v node || true)"
[[ -n "$NODE" ]] || unavailable "node が無い"

WORKDIR="$(mktemp -d)"

if [[ -n "${CODEX_RUN_PLUGIN_ROOT:-}" ]]; then
    PLUGIN_ROOT="$CODEX_RUN_PLUGIN_ROOT"
else
    # Codex のシェルは CLAUDE_CONFIG_DIR を継承しないので、その場合は $HOME/.claude に戻る。
    # 版はディレクトリ名の辞書順で選ばない（1.0.10 < 1.0.6 になる）
    PLUGIN_ROOT="$("$NODE" -e '
        const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        const e = ((j.plugins || {})["codex@openai-codex"] || []).find((x) => x.scope === "user");
        if (e && e.installPath) process.stdout.write(e.installPath);
    ' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json" 2>/dev/null || true)"
fi
COMPANION="$PLUGIN_ROOT/scripts/codex-companion.mjs"
[[ -n "$PLUGIN_ROOT" && -f "$COMPANION" ]] || unavailable "Codex plugin（codex@openai-codex）が見つからない"

"$NODE" "$COMPANION" setup --json >"$WORKDIR/setup.out" 2>"$WORKDIR/setup.err" </dev/null || true
# ready はモデルの妥当性を見ない（モデルの誤りは実行の失敗として下で捕まえる）
setup_reason=""
"$NODE" -e '
    const fs = require("fs");
    let o;
    try { o = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); }
    catch (e) {
        const err = fs.readFileSync(process.argv[2], "utf8").trim().split("\n")[0];
        process.stdout.write("setup --json の出力が読めない" + (err ? ": " + err : ""));
        process.exit(1);
    }
    if (o.ready === true) process.exit(0);
    process.stdout.write(String((o.auth && o.auth.detail) || (o.nextSteps || [])[0] || "Codex の準備ができていない"));
    process.exit(1);
' "$WORKDIR/setup.out" "$WORKDIR/setup.err" >"$WORKDIR/setup.reason" || setup_reason="$(cat "$WORKDIR/setup.reason")"
[[ -z "$setup_reason" ]] || unavailable "setup: ${setup_reason}"

case "$SUB" in
    review)
        # 位置引数は companion が空白で連結するので 1 引数で渡す
        FOCUS="この PR の差分の正しさ（バグ・回帰・テストの穴・横展開の漏れ）。指摘は日本語で"
        rc=0
        "$NODE" "$COMPANION" adversarial-review --json --model "$MODEL" --base "$BASE_REF" -C "$PWD" "$FOCUS" \
            >"$WORKDIR/run.out" 2>"$WORKDIR/run.err" </dev/null || rc=$?
        ;;
    plan)
        PLAN_ABS="$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")"
        PROMPT="$WORKDIR/prompt.md"
        cat >"$PROMPT" <<EOF
あなたは実装計画のレビュアーです。次の計画ファイルを読んでください: ${PLAN_ABS}

計画が参照するコードやファイルを read-only で確かめ、前提の誤り・抜けている経路・実装順序の誤り・根拠のない断言を指摘してください。ファイルは一切変更しないでください。

出力は次の形の JSON オブジェクト 1 つだけにしてください（前後に文章を付けない）。文字列は日本語で書いてください。

{
  "verdict": "approve" または "needs-attention",
  "summary": "全体の評価",
  "findings": [
    {"severity": "critical / high / medium / low のいずれか", "title": "見出し", "body": "根拠を含む説明",
     "file": "対象ファイル", "line_start": 1, "line_end": 1, "confidence": 0.0 から 1.0, "recommendation": "直し方"}
  ],
  "next_steps": ["次にすること"]
}

file は、リポジトリ内のファイルならリポジトリのルートからの相対パス、計画ファイルへの指摘なら上に書いた絶対パスのままにしてください。指摘が無ければ findings は空の配列にしてください。
EOF
        rc=0
        "$NODE" "$COMPANION" task --json --model "$MODEL" --prompt-file "$PROMPT" -C "$PWD" \
            >"$WORKDIR/run.out" 2>"$WORKDIR/run.err" </dev/null || rc=$?
        ;;
esac

# 判定と正規化。companion の exit code は turn の状態だけで決まり、parseError があっても
# turn が completed なら 0 になる（codex-companion.mjs 1.0.6 の L669-671）ので、出力の形も見る。
# 想定内の失敗は rc=10 で理由を返す。それ以外の rc は想定外として EXIT trap に任せる
RESULT_FILE="$WORKDIR/result.json"
nrc=0
verdict="$("$NODE" -e '
    const fs = require("fs");
    const [mode, outF, errF, rcS, resF, rawF] = process.argv.slice(1);
    const rc = Number(rcS);
    const stdout = fs.readFileSync(outF, "utf8");
    const stderr = fs.readFileSync(errF, "utf8").trim();
    const fail = (r) => { process.stdout.write(String(r).slice(0, 2000)); process.exit(10); };
    // 写し方（codex-reviewer.md）が使う項目を、companion の review-output.schema.json と同じ基準で見る。
    // plan モードはスキーマを API に渡さずプロンプトで形を指定するだけなので、ここが唯一の検査になる
    const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
    const str = (v) => typeof v === "string" && v.length > 0;
    const line = (v) => Number.isInteger(v) && v >= 1;
    const finding = (f) => isObj(f) && ["critical", "high", "medium", "low"].includes(f.severity)
        && str(f.title) && str(f.body) && str(f.file) && line(f.line_start) && line(f.line_end)
        && typeof f.confidence === "number" && f.confidence >= 0 && f.confidence <= 1
        && typeof f.recommendation === "string";
    const valid = (r) => isObj(r) && ["approve", "needs-attention"].includes(r.verdict)
        && Array.isArray(r.findings) && r.findings.every(finding);
    let result;
    if (mode === "review") {
        if (rc !== 0) {
            let pe = null;
            try { pe = JSON.parse(stdout).parseError; } catch (e) {}
            fail(stderr || (pe && "parseError: " + pe) || "companion が rc=" + rc + " で終わった");
        }
        // exit 0 なのに JSON でないのは想定外（例外で落とし、EXIT trap に任せる）
        const o = JSON.parse(stdout);
        if (o.parseError) fail("parseError: " + o.parseError);
        if (!valid(o.result)) {
            fs.writeFileSync(rawF, stdout);
            fail("result の形が不正（verdict・findings の項目）");
        }
        result = o.result;
    } else {
        // task --json はエラー文を持たず、turn 中の失敗の文言はジョブログにだけ残る
        let o = null;
        try { o = JSON.parse(stdout); } catch (e) {}
        if (rc !== 0 || !o || o.status !== 0) fail(stderr || "turn が失敗（詳細はジョブログ）");
        const raw = String(o.rawOutput == null ? "" : o.rawOutput);
        const m = raw.match(/```(?:json)?[ \t]*\n([\s\S]*?)\n[ \t]*```/);
        let r = null;
        try { r = JSON.parse(m ? m[1] : raw); } catch (e) {}
        if (!valid(r)) {
            fs.writeFileSync(rawF, raw);
            fail("出力が想定の JSON でない（生の出力は --out と同じ場所の .raw.txt）");
        }
        result = r;
    }
    fs.writeFileSync(resF, JSON.stringify(result));
    process.stdout.write(String(result.findings.length));
' "$SUB" "$WORKDIR/run.out" "$WORKDIR/run.err" "$rc" "$RESULT_FILE" "$WORKDIR/raw.txt")" || nrc=$?

case "$nrc" in
    0) FINDINGS="$verdict"; STATUS="ok"; exit 0 ;;
    10) unavailable "$verdict" ;;
    *) exit "$nrc" ;;
esac
