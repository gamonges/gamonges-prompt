#!/usr/bin/env bash
# review-adr のスクリプト（shared/skills/review-adr/scripts/ の select_lenses.py と
# notion_fetch_body.py）の挙動テスト。
#
# select_lenses.py はプロジェクト固有の観点を ADR の中身で選ぶ。壊れても何かしら 5 本が
# 選ばれて見えるので、通常の動作確認では「中身に反応しない」ことに気づけない。
# notion_fetch_body.py は会話の記録から Notion の本文を取り出す。古い版を拾っても rc=0 で
# 本文が書かれるので、気づけない。どちらも、条件ごとに「その条件だけが崩れれば結果が
# 変わる」入力を置いて確かめる。
#
# スクリプトは /usr/bin/python3（3.9）でも動かす前提なので、python3 と /usr/bin/python3 が
# 別物なら両方で全件を回す。HOME は差し替えない（mise の shim が壊れるため）。
#
# 起動: bash shared/scripts/tests/test-review-adr-scripts.sh

# set -e は使わない。1 件目の失敗で残りが走らなくなると、Red で全件の失敗を確かめられない
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SELECT="$REPO_ROOT/shared/skills/review-adr/scripts/select_lenses.py"
FETCH="$REPO_ROOT/shared/skills/review-adr/scripts/notion_fetch_body.py"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass_count=0
fail_count=0
LABEL=""

pass() { echo -e "${GREEN}[PASS]${NC} ${LABEL}$1"; pass_count=$((pass_count + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} ${LABEL}$1"; fail_count=$((fail_count + 1)); }

BASE="$(mktemp -d)"
WORK="$BASE"
cleanup() { rm -rf "$BASE"; }
trap cleanup EXIT

assert_rc() {  # $1=名前 $2=期待 $3=実際 $4=出力（失敗時に見せる）
    if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1（rc=$3、期待 $2）: ${4:0:400}"; fi
}

assert_has() {  # $1=名前 $2=出力 $3=含むべき文字列
    if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1（「$3」が無い）: ${2:0:400}"; fi
}

assert_eq() {  # $1=名前 $2=期待 $3=実際
    if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1（期待「$2」、実際「$3」）"; fi
}

# ============================================================ select_lenses.py

# description を持つ定義を 1 つ書く。$1=パス（repo からの相対） $2=description の行（複数行可）
put_def() {
    mkdir -p "$(dirname "$R/$1")"
    printf -- '---\nname: x\n%s\n---\n\n本文\n' "$2" > "$R/$1"
}

# 出力の TSV から、パスの status を引く（行が無ければ「absent」）
status_of() {  # $1=出力 $2=パス
    local s
    s="$(printf '%s\n' "$1" | awk -F'\t' -v p="$2" '$3 == p { print $4 }')"
    if [[ -n "$s" ]]; then echo "$s"; else echo "absent"; fi
}

# 採点の規則ごとのケース。各ケースの語は他のケースと重ならないようにし、df を乱さない
make_rules_repo() {
    R="$WORK/rules-repo"
    rm -rf "$R"
    mkdir -p "$R/tmp/adr-review"
    # rules はレビュー語が無くても候補になる（2 語で selected）
    put_def ".claude/rules/tier.md" 'description: "zqrulea と zqruleb の決め方"'
    # skills はレビュー語が無ければ候補にならない（語は 2 つ当たる）
    put_def ".claude/skills/noreview-x/SKILL.md" 'description: zqnra と zqnrb の実装ガイド'
    # 2 文字の漢字は数えない（数えると「対象」で 2 語になり selected になる）
    put_def ".claude/skills/kanji-x/SKILL.md" 'description: 対象 と zqkana のレビュー'
    # 4 本以上の description に出る語は数えない（数えると「共通基盤」で 2 語）
    put_def ".claude/skills/df-x/SKILL.md" 'description: 共通基盤 と zqdfa のレビュー'
    put_def ".claude/skills/fill-1/SKILL.md" 'description: 共通基盤 の手順'
    put_def ".claude/skills/fill-2/SKILL.md" 'description: 共通基盤 の手順'
    put_def ".claude/skills/fill-3/SKILL.md" 'description: 共通基盤 の手順'
    # 3 本の description に出る語は数える（境界。DF_MAX を 1 つ下げると below になる）
    put_def ".claude/skills/df3-x/SKILL.md" 'description: zqdthree と zqdthrb のレビュー'
    put_def ".claude/skills/fill-4/SKILL.md" 'description: zqdthree の手順'
    put_def ".claude/skills/fill-5/SKILL.md" 'description: zqdthree の手順'
    # 固定の除外語は数えない（数えると github で 2 語になり selected）
    put_def ".claude/skills/stop-x/SKILL.md" 'description: github と zqstopa のレビュー'
    # 本スキル群・共有の観点と同名の残りの名前も出ない
    local nm
    for nm in adr-decision-quality fact-check adr-premortem rollout-check adr-lineage adr ddd-expert; do
        put_def ".claude/skills/$nm/SKILL.md" "description: zqex${nm//-/}a と zqex${nm//-/}b のレビュー"
    done
    put_def ".claude/agents/adr-lens-reviewer.md" 'description: zqexlensa と zqexlensb の review'
    # agents と rules の入れ子（**）も走査する（除外に当たらない定義なので selected）
    put_def ".claude/agents/sub/nest-agent.md" 'description: zqnaga と zqnagb の review'
    put_def ".claude/rules/sub/nest-rule.md" 'description: zqnrua と zqnrub の決め方'
    # 得点 1 は below（下限が 1 なら selected になる）
    put_def ".claude/skills/one-x/SKILL.md" 'description: zqonea のレビュー'
    # 本スキル群自身と、共有の観点と同名の定義は出力に出ない（どちらも 2 語当たる）
    put_def ".claude/skills/review-adr/SKILL.md" 'description: zqraa と zqrab のレビュー'
    put_def ".claude/agents/security-auditor.md" 'description: zqsaa と zqsab の review'
    put_def ".claude/skills/coupling-anatomy/SKILL.md" 'description: zqcpa と zqcpb のレビュー'
    # >- の複数行の description を読む（読めなければ absent）
    put_def ".claude/skills/ml-x/SKILL.md" $'description: >-\n  zqmla の\n  zqmlb のレビュー'
    # frontmatter と「- 入力:」の行にだけ出る語は加点しない（加点すると 2 語で selected）
    put_def ".claude/skills/path-x/SKILL.md" 'description: zqpatha と zqpathb のレビュー'
    # frontmatter の無いルールは候補にならない（本文の description: の行を frontmatter と読まない）
    mkdir -p "$R/.claude/rules"
    printf '# frontmatter なし\n\ndescription: zqnfma と zqnfmb の決め方\n' > "$R/.claude/rules/nofm.md"
    # 対象 repo の名前（origin の URL の末尾）に含まれる語は数えない（製品名の雑音。数えると 2 語で selected）
    put_def ".claude/skills/prod-x/SKILL.md" 'description: zqacme と zqprodb のレビュー'
    git -C "$R" init -q
    git -C "$R" remote add origin "https://example.invalid/org/zqacmeshop-api.git"
    cat > "$R/tmp/adr-review/_target.md" <<'EOF'
---
type: ADR Review
title: 対象の ADR — zqpathb のテスト
description: review-adr のスナップショット。/x/zqpathb/adr.md の元の属性と本文
status: stable
---
# 対象の ADR — テスト

## 元の属性

- 入力: /x/zqpathb/adr.md
- タグ: zqrulea

## 本文

zqruleb を決める。対象 は 共通基盤 で、zqnra zqnrb zqkana zqdfa zqonea を扱う。
zqraa zqrab zqsaa zqsab zqcpa zqcpb zqacme zqprodb zqdthree zqdthrb github zqstopa zqexlensa zqexlensb zqexadrdecisionqualitya zqexadrdecisionqualityb zqexfactchecka zqexfactcheckb zqexadrpremortema zqexadrpremortemb zqexrolloutchecka zqexrolloutcheckb zqexadrlineagea zqexadrlineageb zqexadra zqexadrb zqexdddexperta zqexdddexpertb zqnaga zqnagb zqnrua zqnrub zqmla zqmlb zqpatha zqnfma zqnfmb。
EOF
}

# 上限 5 本と同点の決め方（得点 → 出現回数の合計 → パスの辞書順）
make_limit_repo() {
    R="$WORK/limit-repo"
    rm -rf "$R"
    mkdir -p "$R/tmp/adr-review"
    put_def ".claude/skills/s3/SKILL.md" 'description: zqs1 zqs2 zqs3 のレビュー'
    put_def ".claude/skills/t3/SKILL.md" 'description: zqt1 zqt2 zqt3 のレビュー'
    put_def ".claude/skills/e2/SKILL.md" 'description: zqe1 zqe2 のレビュー'
    put_def ".claude/skills/b2/SKILL.md" 'description: zqb1 zqb2 のレビュー'
    put_def ".claude/skills/c2/SKILL.md" 'description: zqc1 zqc2 のレビュー'
    put_def ".claude/skills/f2/SKILL.md" 'description: zqf1 zqf2 のレビュー'
    put_def ".claude/skills/d2/SKILL.md" 'description: zqd1 zqd2 のレビュー'
    # 出現回数: e2 = 6、b2・c2・f2 = 4、d2 = 2。パスの辞書順だけなら d2 が e2・f2 より先に来る
    cat > "$R/tmp/adr-review/_target.md" <<'EOF'
---
type: ADR Review
title: 対象の ADR — 上限
description: review-adr のスナップショット
status: stable
---
## 本文

zqs1 zqs2 zqs3 zqt1 zqt2 zqt3
zqe1 zqe1 zqe1 zqe2 zqe2 zqe2
zqb1 zqb1 zqb2 zqb2
zqc1 zqc1 zqc2 zqc2
zqf1 zqf1 zqf2 zqf2
zqd1 zqd2
EOF
}

run_select_tests() {
    local out rc
    make_rules_repo
    out="$("$PY" "$SELECT" "$R" "$R/tmp/adr-review/_target.md" 2>&1)"; rc=$?
    assert_rc "SL 規則のケースで rc=0" 0 "$rc" "$out"
    assert_eq "SL rules はレビュー語なしで候補になる" "selected" "$(status_of "$out" .claude/rules/tier.md)"
    assert_eq "SL skills はレビュー語が無ければ候補にならない" "absent" "$(status_of "$out" .claude/skills/noreview-x/SKILL.md)"
    assert_eq "SL 2 文字の漢字は数えない" "below" "$(status_of "$out" .claude/skills/kanji-x/SKILL.md)"
    assert_eq "SL 4 本以上の description に出る語は数えない" "below" "$(status_of "$out" .claude/skills/df-x/SKILL.md)"
    assert_eq "SL 得点 1 は below" "below" "$(status_of "$out" .claude/skills/one-x/SKILL.md)"
    assert_eq "SL 本スキル群自身は出ない" "absent" "$(status_of "$out" .claude/skills/review-adr/SKILL.md)"
    assert_eq "SL 共有の観点と同名の定義は出ない" "absent" "$(status_of "$out" .claude/agents/security-auditor.md)"
    assert_eq "SL 共有の観点と同名のスキルも出ない" "absent" "$(status_of "$out" .claude/skills/coupling-anatomy/SKILL.md)"
    assert_eq "SL >- の複数行の description を読む" "selected" "$(status_of "$out" .claude/skills/ml-x/SKILL.md)"
    assert_eq "SL frontmatter と入力の行にだけ出る語は加点しない" "below" "$(status_of "$out" .claude/skills/path-x/SKILL.md)"
    assert_eq "SL frontmatter の無いルールは候補にならない" "absent" "$(status_of "$out" .claude/rules/nofm.md)"
    assert_eq "SL 3 本の description に出る語は数える（境界）" "selected" "$(status_of "$out" .claude/skills/df3-x/SKILL.md)"
    assert_eq "SL 固定の除外語は数えない" "below" "$(status_of "$out" .claude/skills/stop-x/SKILL.md)"
    for nm in adr-decision-quality fact-check adr-premortem rollout-check adr-lineage adr ddd-expert; do
        assert_eq "SL 除外の名前 $nm は出ない" "absent" "$(status_of "$out" ".claude/skills/$nm/SKILL.md")"
    done
    assert_eq "SL 除外の名前 adr-lens-reviewer は出ない" "absent" "$(status_of "$out" .claude/agents/adr-lens-reviewer.md)"
    assert_eq "SL agents の入れ子も走査する" "selected" "$(status_of "$out" .claude/agents/sub/nest-agent.md)"
    assert_eq "SL rules の入れ子も走査する" "selected" "$(status_of "$out" .claude/rules/sub/nest-rule.md)"
    assert_eq "SL 対象 repo の名前に含まれる語は数えない" "below" "$(status_of "$out" .claude/skills/prod-x/SKILL.md)"
    assert_eq "SL rules の得点と語" $'2\tzqrulea zqruleb' \
        "$(printf '%s\n' "$out" | awk -F'\t' '$3 == ".claude/rules/tier.md" { print $1 "\t" $5 }')"

    make_limit_repo
    out="$("$PY" "$SELECT" "$R" "$R/tmp/adr-review/_target.md" 2>&1)"; rc=$?
    assert_rc "SL 上限のケースで rc=0" 0 "$rc" "$out"
    assert_eq "SL 得点 → 出現回数 → パスの順に並び、5 本で切る" \
        "s3:selected t3:selected e2:selected b2:selected c2:selected f2:dropped d2:dropped" \
        "$(printf '%s\n' "$out" | awk -F'\t' '{ split($3, a, "/"); printf "%s%s:%s", (NR > 1 ? " " : ""), a[3], $4 }')"
    assert_eq "SL 出現回数の合計を 2 列目に出す" "6" \
        "$(printf '%s\n' "$out" | awk -F'\t' '$3 == ".claude/skills/e2/SKILL.md" { print $2 }')"

    # origin が無い worktree では、共有の .git の親の名前を repo の名前にする
    local main="$WORK/zqbetashop-svc" wt="$WORK/feature-branch"
    rm -rf "$main" "$wt"
    git init -q "$main"
    git -C "$main" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
    git -C "$main" worktree add -q "$wt" -b zqfeature 2>/dev/null
    R="$wt"
    mkdir -p "$R/tmp/adr-review"
    put_def ".claude/skills/beta-x/SKILL.md" 'description: zqbeta と zqbetb のレビュー'
    printf -- '---\ntype: ADR Review\n---\n## 本文\n\nzqbeta zqbetb\n' > "$R/tmp/adr-review/_target.md"
    out="$("$PY" "$SELECT" "$R" "$R/tmp/adr-review/_target.md" 2>&1)"; rc=$?
    assert_rc "SL worktree のケースで rc=0" 0 "$rc" "$out"
    assert_eq "SL worktree では共有の .git の親の名前の語を数えない" "below" "$(status_of "$out" .claude/skills/beta-x/SKILL.md)"

    # 候補が 0 件でも rc=0 で、出力は空
    local empty="$WORK/empty-repo"
    rm -rf "$empty"
    mkdir -p "$empty/tmp/adr-review"
    printf -- '---\ntype: ADR Review\n---\n## 本文\n\nzqnone\n' > "$empty/tmp/adr-review/_target.md"
    out="$("$PY" "$SELECT" "$empty" "$empty/tmp/adr-review/_target.md" 2>&1)"; rc=$?
    assert_rc "SL 候補が 0 件でも rc=0" 0 "$rc" "$out"
    assert_eq "SL 候補が 0 件なら出力は空" "" "$out"

    # 引数の誤り: 対象 repo が無い・引数の数が違うときは rc=2
    out="$("$PY" "$SELECT" "$WORK/no-such-repo" "$empty/tmp/adr-review/_target.md" 2>&1)"; rc=$?
    assert_rc "SL 対象 repo が無ければ rc=2" 2 "$rc" "$out"
    assert_has "SL 対象 repo が無いときのメッセージ" "$out" "select_lenses.py: 対象 repo が無い"
    out="$("$PY" "$SELECT" "$empty" 2>&1)"; rc=$?
    assert_rc "SL 引数が足りなければ rc=2" 2 "$rc" "$out"
    assert_has "SL 引数が足りないときのメッセージ" "$out" "select_lenses.py: 使い方"

    # 引数の誤り: _target.md が無ければ rc=2
    out="$("$PY" "$SELECT" "$R" "$R/tmp/adr-review/none.md" 2>&1)"; rc=$?
    assert_rc "SL _target.md が無ければ rc=2" 2 "$rc" "$out"
    assert_has "SL _target.md が無いときのメッセージ" "$out" "select_lenses.py: "
}

# ============================================================ notion_fetch_body.py

PAGE_A="0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a"
PAGE_B="0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"
PAGE_C="0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c"
PAGE_D="0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d"

# 記録の 1 往復（tool_use と tool_result の 2 行）を書く。$1=ファイル $2=時刻 $3=use id $4=URL $5=本文の目印
# $6=結果の形（ok = 既定 / nojson = JSON でない結果 / nocontent = <content> の無い結果 / nots = tool_use に timestamp なし）
put_fetch() {
    "$PY" - "$@" <<'EOF'
import json, sys
path, ts, uid, url, mark = sys.argv[1:6]
kind = sys.argv[6] if len(sys.argv) > 6 else "ok"
text = ("Here is the result of \"fetch\" for the Page with URL " + url + "\n"
        "<page url=\"" + url + "\">\n<properties>\n{\"名前\":\"" + mark + "\"}\n</properties>\n"
        "<content>\n# " + mark + "\n\n本文 " + mark + "\n</content>\n</page>\n"
        "<parent-data-source-schema>x</parent-data-source-schema>")
if kind == "nocontent":
    text = text.split("<content>")[0]
result = json.dumps({"metadata": {"type": "page"}, "title": mark, "url": url, "text": text},
                    ensure_ascii=False)
if kind == "nojson":
    result = "Error: fetch failed <content>" + mark + "</content>"
use = {"type": "assistant", "timestamp": ts, "message": {"content": [
    {"type": "tool_use", "id": uid, "name": "mcp__claude_ai_Notion__notion-fetch",
     "input": {"id": url}}]}}
res = {"type": "user", "timestamp": ts, "message": {"content": [
    {"type": "tool_result", "tool_use_id": uid, "content": result}]}}
if kind == "nots":
    del use["timestamp"]
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(use, ensure_ascii=False) + "\n")
    f.write(json.dumps(res, ensure_ascii=False) + "\n")
EOF
}

make_transcripts() {
    CFG="$WORK/cfg"
    rm -rf "$CFG"
    CWD="$WORK/the.repo_x"
    mkdir -p "$CWD"
    # 記録の置き場所: cwd の英数字以外を - にした名前
    PROJ="$CFG/projects/$(printf '%s' "$CWD" | sed 's/[^A-Za-z0-9]/-/g')"
    mkdir -p "$PROJ/old-session" "$PROJ/now-session/subagents"
    local old="$PROJ/old-session.jsonl" now="$PROJ/now-session.jsonl"
    put_fetch "$old" "2026-11-01T10:00:00.100Z" "u-old-a" "https://app.notion.com/p/$PAGE_A" "OLD-A"
    put_fetch "$old" "2026-11-01T10:00:05.100Z" "u-old-b" "https://app.notion.com/p/$PAGE_B" "OLD-B"
    printf '{壊れた行\n' >> "$now"
    put_fetch "$now" "2026-11-20T09:00:00.500Z" "u-now-a1" "https://app.notion.com/p/$PAGE_A?pvs=204" "NOW-A1"
    put_fetch "$now" "2026-11-20T09:05:00.250Z" "u-now-a2" "https://www.notion.so/x-$PAGE_A" "NOW-A2"
    # 古い版を新しい版より後ろの行に置く（行の順でなく時刻で最新を採ることを確かめる）
    put_fetch "$now" "2026-11-20T09:02:00.000Z" "u-now-a-late" "https://app.notion.com/p/$PAGE_A" "LATE-LINE-OLD-A"
    # 記録の側の URL に ?pvs= が付いていても引ける（候補はこれだけ）
    put_fetch "$now" "2026-11-20T09:30:00.000Z" "u-d-pvs" "https://app.notion.com/p/$PAGE_D?pvs=204" "PVS-D"
    # 開けない記録（.jsonl という名前のディレクトリ）は飛ばす。飛ばせないと rc=0 の全ケースが落ちる
    mkdir -p "$PROJ/zz-unreadable.jsonl"
    # 成功の後に不適格な結果が続いても、成功を採る（後ろの失敗した取得が前の成功を隠さない）
    put_fetch "$now" "2026-11-20T10:00:00.000Z" "u-c-ok" "https://app.notion.com/p/$PAGE_C" "OK-C"
    put_fetch "$now" "2026-11-20T10:01:00.000Z" "u-c-nojson" "https://app.notion.com/p/$PAGE_C" "NOJSON-C" nojson
    put_fetch "$now" "2026-11-20T10:02:00.000Z" "u-c-nocontent" "https://app.notion.com/p/$PAGE_C" "NOCONTENT-C" nocontent
    put_fetch "$now" "2026-11-20T10:03:00.000Z" "u-c-nots" "https://app.notion.com/p/$PAGE_C" "NOTS-C" nots
    # サブエージェントの記録にあるものも候補になる
    put_fetch "$PROJ/now-session/subagents/agent-1.jsonl" "2026-11-20T09:06:00.000Z" "u-sub-b" \
        "https://app.notion.com/p/$PAGE_B" "SUB-B"
}

fetch() { CLAUDE_CONFIG_DIR="$CFG" "$PY" "$FETCH" "$@"; }

run_fetch_tests() {
    local out rc o="$WORK/o"
    make_transcripts
    mkdir -p "$o"

    rm -f "$o"/*
    out="$(fetch --page "https://app.notion.com/p/$PAGE_A" --cwd "$CWD" --since 2026-11-20T08:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF --since 以降の同じページがあれば rc=0" 0 "$rc" "$out"
    assert_eq "NF --since 以降の候補のうち新しい方の本文を書く" $'\n# NOW-A2\n\n本文 NOW-A2\nx' "$(cat "$o/body" 2>/dev/null; printf x)"
    assert_eq "NF 属性は <properties> の中身だけを書く" $'\n{"名前":"NOW-A2"}\nx' "$(cat "$o/props" 2>/dev/null; printf x)"

    rm -f "$o"/*
    out="$(fetch --page "${PAGE_A:0:8}-${PAGE_A:8:4}-${PAGE_A:12:4}-${PAGE_A:16:4}-${PAGE_A:20}" --cwd "$CWD" \
        --since 2026-11-20T09:01:00Z --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF ハイフン付きの ID で引ける" 0 "$rc" "$out"
    assert_eq "NF ハイフン付きの ID で引いた本文" "NOW-A2" "$(sed -n 's/^# //p' "$o/body" 2>/dev/null)"

    rm -f "$o"/*
    # 記録は 09:05:00.250Z、--since は 09:05:00Z。文字列で比べると「.」<「Z」で記録が前に見え、候補から落ちる
    out="$(fetch --page "$PAGE_A" --cwd "$CWD" --since 2026-11-20T09:05:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF ハイフン無しの ID で引け、時刻は解析して比べる" 0 "$rc" "$out"
    assert_eq "NF 小数秒のある記録を --since と比べて採る" "NOW-A2" "$(sed -n 's/^# //p' "$o/body" 2>/dev/null)"

    rm -f "$o"/*
    out="$(fetch --page "$PAGE_B" --cwd "$CWD" --since 2026-11-20T00:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF サブエージェントの記録も候補にする" 0 "$rc" "$out"
    assert_eq "NF サブエージェントの記録の本文" "SUB-B" "$(sed -n 's/^# //p' "$o/body" 2>/dev/null)"

    rm -f "$o"/*
    out="$(fetch --page "https://app.notion.com/p/$PAGE_A?pvs=204" --cwd "$CWD" --since 2026-11-20T08:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF --page に ?pvs= 付きの URL を渡しても引ける" 0 "$rc" "$out"
    assert_eq "NF ?pvs= 付きの URL で引いた本文" "NOW-A2" "$(sed -n 's/^# //p' "$o/body" 2>/dev/null)"

    rm -f "$o"/*
    out="$(fetch --page "$PAGE_D" --cwd "$CWD" --since 2026-11-20T00:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF 記録の側の ?pvs= 付きの URL も一致とみなす" 0 "$rc" "$out"
    assert_eq "NF 記録の側の ?pvs= 付きの URL の本文" "PVS-D" "$(sed -n 's/^# //p' "$o/body" 2>/dev/null)"

    rm -f "$o"/*
    out="$(fetch --page "$PAGE_A" --cwd "$CWD" --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF 必須の引数（--since）が無ければ rc=2" 2 "$rc" "$out"
    assert_has "NF 必須の引数が無いときのメッセージ" "$out" "notion_fetch_body.py: 引数の誤り"

    rm -f "$o"/*
    out="$(fetch --page "$PAGE_C" --cwd "$CWD" --since 2026-11-20T00:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF 成功の後に不適格な結果が続いても rc=0" 0 "$rc" "$out"
    assert_eq "NF JSON でない・<content> の無い・timestamp の無い後ろの結果は採らない" "OK-C" "$(sed -n 's/^# //p' "$o/body" 2>/dev/null)"

    # 負例: 今回（--since 以降）の結果が無く、過去のセッションにだけ同じページの成功結果がある
    rm -f "$o"/*
    out="$(fetch --page "$PAGE_A" --cwd "$CWD" --since 2026-11-21T00:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF 過去のセッションにしか無ければ rc=1" 1 "$rc" "$out"
    assert_has "NF 候補が無いときのメッセージ" "$out" "notion_fetch_body.py: --since 以降の notion-fetch の結果が無い"
    assert_eq "NF rc=1 のときは --out も --props-out も作らない" "" "$(ls "$o")"

    rm -f "$o"/*
    out="$(fetch --page "0123456789abcdef0123456789abcdef" --cwd "$CWD" --since 2026-11-01T00:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF 一致するページが無ければ rc=1" 1 "$rc" "$out"
    assert_has "NF 一致するページが無いときのメッセージ" "$out" "notion_fetch_body.py: --since 以降の notion-fetch の結果が無い"

    rm -f "$o"/*
    out="$(fetch --page "not-a-page" --cwd "$CWD" --since 2026-11-01T00:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF ページ ID を読めなければ rc=2" 2 "$rc" "$out"
    assert_has "NF ページ ID を読めないときのメッセージ" "$out" "notion_fetch_body.py: "

    rm -f "$o"/*
    out="$(fetch --page "$PAGE_A" --cwd "$CWD" --since "昨日" \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF --since を読めなければ rc=2" 2 "$rc" "$out"
    assert_has "NF --since を読めないときのメッセージ" "$out" "notion_fetch_body.py: "
}

# ============================================================ 実行

PYS=(python3)
if [[ -x /usr/bin/python3 ]] && \
    [[ "$(/usr/bin/python3 -c 'import sys; print(sys.version)')" != "$(python3 -c 'import sys; print(sys.version)')" ]]; then
    PYS+=(/usr/bin/python3)
fi

for f in "$SELECT" "$FETCH"; do
    [[ -f "$f" ]] || echo "test-review-adr-scripts.sh: 検査対象が見つからない: $f" >&2
done

run_no=0
for PY in "${PYS[@]}"; do
    run_no=$((run_no + 1))
    WORK="$BASE/run-$run_no"
    mkdir -p "$WORK"
    LABEL="[$("$PY" -c 'import sys; print("py%d.%d" % sys.version_info[:2])')] "
    echo "== ${PY}（$("$PY" --version 2>&1)）=="
    run_select_tests
    run_fetch_tests
done

echo
echo "${pass_count} passed / ${fail_count} failed（python: ${PYS[*]}）"
[[ "$fail_count" -eq 0 ]] || exit 1
