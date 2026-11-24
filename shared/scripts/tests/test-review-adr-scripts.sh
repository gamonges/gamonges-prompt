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
GUARD="$REPO_ROOT/shared/skills/review-adr/scripts/input_guard.py"

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

# 書き先の名前（6 列目）と、rules への除外の効き方。名前は全行について決めるので、語は ADR に出さなくてよい
make_names_repo() {
    R="$WORK/names-repo"
    rm -rf "$R"
    mkdir -p "$R/tmp/adr-review"
    local rel
    for rel in frontend/testing backend/testing codex unified adr-self-review _x security-auditor tier a-b/zt a/b/zt rules-codex; do
        put_def ".claude/rules/$rel.md" "description: zqnm${rel//[^a-z]/}a の決め方"
    done
    # 本スキル群・共有の観点と同じ名前のルールも候補にする（除外は skills・agents だけ）
    put_def ".claude/rules/adr.md" 'description: zqrladra と zqrladrb の決め方'
    put_def ".claude/rules/fact-check.md" 'description: zqrlfca と zqrlfcb の決め方'
    printf -- '---\ntype: ADR Review\n---\n## 本文\n\nzqrladra zqrladrb zqrlfca zqrlfcb\n' > "$R/tmp/adr-review/_target.md"
}

name_of_row() {  # $1=出力 $2=パス → 6 列目
    printf '%s\n' "$1" | awk -F'\t' -v p="$2" '$3 == p { print $6 }'
}

# description の読み方（次の行から始まる値・plain の続き・コメント）
make_yaml_repo() {
    R="$WORK/yaml-repo"
    rm -rf "$R"
    mkdir -p "$R/tmp/adr-review"
    put_def ".claude/skills/next-line/SKILL.md" $'description:\n  zqnla と zqnlb のレビュー'
    put_def ".claude/skills/plain-cont/SKILL.md" $'description: zqpla の\n  zqplb のレビュー'
    put_def ".claude/skills/plain-cmt/SKILL.md" $'description: zqpcm の\n  # zqplc\n  zqplx  # zqpld\n  のレビュー'
    put_def ".claude/skills/block-hash/SKILL.md" $'description: >-\n  zqbha の\n  # zqbhb のレビュー'
    put_def ".claude/skills/next-key/SKILL.md" $'description: zqnka\n  zqnkb のレビュー\nother: zqnkc'
    put_def ".claude/skills/quoted-cmt/SKILL.md" $'description: "zqqca と zqqcb のレビュー" # zqqcc'
    put_def ".claude/skills/quoted-esc/SKILL.md" $'description: \'zqqea と zqqeb\'\'s のレビュー\''
    put_def ".claude/skills/dquoted-esc/SKILL.md" $'description: "zqdea と \\"zqdeb\\" のレビュー"'
    put_def ".claude/skills/block-keep/SKILL.md" $'description: >+\n  zqbka の\n  # zqbkb のレビュー'
    printf -- '---\ntype: ADR Review\n---\n## 本文\n\nzqnla zqnlb zqpla zqplb zqpcm zqplc zqplx zqpld zqbha zqbhb zqnka zqnkb zqnkc zqqca zqqcb zqqcc zqbka zqbkb zqqea zqqeb zqdea zqdeb\n' \
        > "$R/tmp/adr-review/_target.md"
}

words_of_row() {  # $1=出力 $2=パス → 5 列目
    printf '%s\n' "$1" | awk -F'\t' -v p="$2" '$3 == p { print $5 }'
}

# 読めない定義・BOM（警告は stderr だけに出し、TSV に混ぜない）
make_enc_repo() {
    R="$WORK/enc-repo"
    rm -rf "$R"
    mkdir -p "$R/tmp/adr-review" "$R/.claude/skills/bom-x" "$R/.claude/skills/latin" "$R/.claude/rules"
    printf '\xef\xbb\xbf---\nname: x\ndescription: zqboma と zqbomb のレビュー\n---\n' > "$R/.claude/skills/bom-x/SKILL.md"
    printf -- '---\nname: x\ndescription: zqlat \xff のレビュー\n---\n' > "$R/.claude/skills/latin/SKILL.md"
    printf -- '---\npaths: src\n---\n\n本文\n' > "$R/.claude/rules/paths-only.md"
    printf -- '---\ndescription: zqlatr \xff の決め方\n---\n' > "$R/.claude/rules/latin-rule.md"
    printf '# frontmatter なし\n' > "$R/.claude/rules/nofm2.md"
    mkdir -p "$R/.claude/skills/nodesc"
    printf -- '---\nname: x\n---\n' > "$R/.claude/skills/nodesc/SKILL.md"
    printf -- '---\ntype: ADR Review\n---\n## 本文\n\nzqboma zqbomb zqlat zqlatr\n' > "$R/tmp/adr-review/_target.md"
}

# 英字の語の単語境界と、カタカナ・漢字の最小 3 文字
make_word_repo() {
    R="$WORK/word-repo"
    rm -rf "$R"
    mkdir -p "$R/tmp/adr-review"
    put_def ".claude/skills/sub-x/SKILL.md" 'description: zqauth と zqapi のレビュー'
    put_def ".claude/skills/wb-x/SKILL.md" 'description: zqwba と zqwbb のレビュー'
    put_def ".claude/skills/kana-x/SKILL.md" 'description: ゾキラ と 認可層 のレビュー'
    put_def ".claude/skills/kana2-x/SKILL.md" 'description: ゾキ と zqkntwo のレビュー'
    printf -- '---\ntype: ADR Review\n---\n## 本文\n\nzqauthor と xzqapi。zqwba を使う。zqwbbを使う。ゾキラ と 認可層。ゾキ と zqkntwo。\n' \
        > "$R/tmp/adr-review/_target.md"
}

run_select_more_tests() {
    local out rc err="$WORK/select.err"
    make_names_repo
    out="$("$PY" "$SELECT" "$R" "$R/tmp/adr-review/_target.md" 2>&1)"; rc=$?
    assert_rc "SL 名前のケースで rc=0" 0 "$rc" "$out"
    assert_eq "SL 衝突しない名前はそのまま" "tier" "$(name_of_row "$out" .claude/rules/tier.md)"
    assert_eq "SL regression: 同じ名前は長い名前にする（frontend）" "rules-frontend-testing" "$(name_of_row "$out" .claude/rules/frontend/testing.md)"
    assert_eq "SL regression: 同じ名前は長い名前にする（backend）" "rules-backend-testing" "$(name_of_row "$out" .claude/rules/backend/testing.md)"
    assert_eq "SL 予約名 codex は長い名前" "rules-codex" "$(name_of_row "$out" .claude/rules/codex.md)"
    assert_eq "SL 予約名 unified は長い名前" "rules-unified" "$(name_of_row "$out" .claude/rules/unified.md)"
    assert_eq "SL 予約名 adr-self-review は長い名前" "rules-adr-self-review" "$(name_of_row "$out" .claude/rules/adr-self-review.md)"
    assert_eq "SL _ で始まる名前は長い名前" "rules-_x" "$(name_of_row "$out" .claude/rules/_x.md)"
    assert_eq "SL 共有の観点と同じ名前は長い名前" "rules-security-auditor" "$(name_of_row "$out" .claude/rules/security-auditor.md)"
    assert_eq "SL 長い名前同士の衝突は -2 を付ける（辞書順で前）" "rules-a-b-zt" "$(name_of_row "$out" .claude/rules/a-b/zt.md)"
    assert_eq "SL 長い名前同士の衝突は -2 を付ける（辞書順で後）" "rules-a-b-zt-2" "$(name_of_row "$out" .claude/rules/a/b/zt.md)"
    assert_eq "SL 既定名がそれまでに決めた名前に当たれば長い名前" "rules-rules-codex" "$(name_of_row "$out" .claude/rules/rules-codex.md)"
    assert_eq "SL 6 列目は全行で一意" "0" "$(printf '%s\n' "$out" | awk -F'\t' 'NF >= 6 { c[$6]++ } END { n = 0; for (k in c) if (c[k] > 1) n++; print n }')"
    assert_eq "SL 6 列目は全行にある" "0" "$(printf '%s\n' "$out" | awk -F'\t' 'NF < 6 || $6 == "" { n++ } END { print n + 0 }')"
    assert_eq "SL regression: 本スキル群と同じ名前のルールも候補にする（adr）" "selected" "$(status_of "$out" .claude/rules/adr.md)"
    assert_eq "SL regression: 本スキル群と同じ名前のルールも候補にする（fact-check）" "selected" "$(status_of "$out" .claude/rules/fact-check.md)"
    assert_eq "SL 同じ名前のルールの書き先は長い名前" "rules-adr" "$(name_of_row "$out" .claude/rules/adr.md)"

    make_yaml_repo
    out="$("$PY" "$SELECT" "$R" "$R/tmp/adr-review/_target.md" 2>&1)"; rc=$?
    assert_rc "SL YAML のケースで rc=0" 0 "$rc" "$out"
    # 状態は上限（5 本）で dropped にもなるので、当たった語で確かめる
    assert_eq "SL regression: 次の行から始まる値を読む" "zqnla zqnlb" "$(words_of_row "$out" .claude/skills/next-line/SKILL.md)"
    assert_eq "SL regression: plain の続きの行を読む" "zqpla zqplb" "$(words_of_row "$out" .claude/skills/plain-cont/SKILL.md)"
    assert_eq "SL plain の続きのコメントは数えない" "zqpcm zqplx" "$(words_of_row "$out" .claude/skills/plain-cmt/SKILL.md)"
    assert_eq "SL ブロックの中の # は本文として数える" "zqbha zqbhb" "$(words_of_row "$out" .claude/skills/block-hash/SKILL.md)"
    assert_eq "SL インデントの無い次のキーで止まる" "zqnka zqnkb" "$(words_of_row "$out" .claude/skills/next-key/SKILL.md)"
    assert_eq "SL regression: 引用符の値の後ろのコメントは数えない" "zqqca zqqcb" "$(words_of_row "$out" .claude/skills/quoted-cmt/SKILL.md)"
    assert_eq "SL regression: 一重引用符の中の \'\' で値を切らない" "zqqea zqqeb" "$(words_of_row "$out" .claude/skills/quoted-esc/SKILL.md)"
    assert_eq "SL regression: 二重引用符の中の \\\" で値を切らない" "zqdea zqdeb" "$(words_of_row "$out" .claude/skills/dquoted-esc/SKILL.md)"
    assert_eq "SL regression: >+ もブロックとして読み、中の # を残す" "zqbka zqbkb" "$(words_of_row "$out" .claude/skills/block-keep/SKILL.md)"

    make_enc_repo
    out="$("$PY" "$SELECT" "$R" "$R/tmp/adr-review/_target.md" 2>"$err")"; rc=$?
    local e; e="$(cat "$err")"
    assert_rc "SL 読めない定義があっても rc=0" 0 "$rc" "$out$e"
    assert_eq "SL regression: BOM 付きの定義を読む" "selected" "$(status_of "$out" .claude/skills/bom-x/SKILL.md)"
    assert_has "SL regression: 非 UTF-8 の skills の定義を stderr に出す" "$e" "select_lenses.py: 読めない定義: .claude/skills/latin/SKILL.md"
    assert_has "SL 非 UTF-8 の rules の定義も stderr に出す" "$e" "select_lenses.py: 読めない定義: .claude/rules/latin-rule.md"
    assert_has "SL skills の description の無い定義を stderr に出す" "$e" "select_lenses.py: description が無い: .claude/skills/nodesc/SKILL.md"
    assert_eq "SL rules の description の無い定義・frontmatter の無いルールは stderr に出さない" "" \
        "$(printf '%s\n' "$e" | grep -e paths-only -e nofm2)"
    assert_eq "SL 警告は TSV（stdout）に混ぜない" "" "$(printf '%s\n' "$out" | grep -e 'select_lenses.py:')"

    make_word_repo
    out="$("$PY" "$SELECT" "$R" "$R/tmp/adr-review/_target.md" 2>&1)"; rc=$?
    assert_rc "SL 語の境界のケースで rc=0" 0 "$rc" "$out"
    assert_eq "SL regression: 英字の語は部分一致で当てない" "below" "$(status_of "$out" .claude/skills/sub-x/SKILL.md)"
    assert_eq "SL 英字の語は単独の語・日本語の文字に続く語に当てる" "selected" "$(status_of "$out" .claude/skills/wb-x/SKILL.md)"
    assert_eq "SL 英字の語の出現回数も単語で数える" "2" "$(printf '%s\n' "$out" | awk -F'\t' '$3 == ".claude/skills/wb-x/SKILL.md" { print $2 }')"
    assert_eq "SL カタカナ 3 文字・漢字 3 文字は数える（境界）" "selected" "$(status_of "$out" .claude/skills/kana-x/SKILL.md)"
    assert_eq "SL カタカナ 2 文字は数えない（境界）" "below" "$(status_of "$out" .claude/skills/kana2-x/SKILL.md)"

    # EXCLUDE と selection.md の表の一致。行の数も出し、表の構文が変わって 0 行を読む（無言で通る）のを捕まえる
    out="$("$PY" - "$REPO_ROOT/shared/skills/review-adr/reference/selection.md" "$SELECT" <<'EOF'
import importlib.util, re, sys
md = open(sys.argv[1], encoding="utf-8").read()
spec = importlib.util.spec_from_file_location("sl", sys.argv[2])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
names = {"review-adr", "adr-lens-reviewer"}
full = [l for l in md.split("\n") if l.startswith("| full")]
names.update(re.findall(r"`([a-z-]+)`", full[0]) if full else ["?full"])
sec = md.split("## 既存の観点")[1].split("###")[0]
rows = [l for l in sec.split("\n") if l.startswith("| ") and not l.startswith("| 観点")]
for l in rows:
    col = l.split("|")[4]
    mm = re.search(r"<skills>/([a-z-]+)/", col) or re.search(r"`([a-z-]+)` の定義", col)
    names.add(mm.group(1) if mm else "?" + l[:20])
print(str(len(full)) + " " + str(len(rows)) + " [" + " ".join(sorted(names - m.EXCLUDE)) + "]")
EOF
)"
    assert_eq "SL EXCLUDE が selection.md の表の名前を全部持つ（full の行 1・既存の観点 4 行）" "1 4 []" "$out"
}

# ============================================================ notion_fetch_body.py

PAGE_A="0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a"
PAGE_B="0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"
PAGE_C="0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c"
PAGE_D="0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d"
PAGE_E="0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e"
PAGE_F="0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f"
PAGE_G="1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a"
PAGE_H="1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b"
DB_X="1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c"
PAGE_I="1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e"
VIEW_X="1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d"

# 記録の 1 往復（tool_use と tool_result の 2 行）を書く。$1=ファイル $2=時刻 $3=use id $4=URL $5=本文の目印
# $6=結果の形（ok = 既定 / nojson = JSON でない結果 / nocontent = <content> の無い結果 / nots = tool_use に timestamp なし
#   / empty = <content> が空白だけ / propsclose = 本文に文字列 </properties> がある）
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
if kind == "empty":
    text = text.split("<content>")[0] + "<content>\n  \n</content>\n</page>\n"
if kind == "surrogate":
    text = text.replace("本文 " + mark, "本文 " + mark + " SURRMARK")
if kind == "propsclose":
    text = text.replace("本文 " + mark, "本文 " + mark + " の例: </properties> で閉じる")
result = json.dumps({"metadata": {"type": "page"}, "title": mark, "url": url, "text": text},
                    ensure_ascii=False)
if kind == "surrogate":
    result = result.replace("SURRMARK", chr(92) + "ud800")
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
    # 開けない記録（.jsonl という名前のディレクトリ）は飛ばす。飛ばせないと rc=0 の全ケースが落ちる。
    # --session の走査に入る場所（今回のセッションの subagents/）に置く
    mkdir -p "$PROJ/now-session/subagents/zz-unreadable.jsonl"
    # 同じ worktree の別のチャット（別セッション）が、同じページをより新しく開いた
    put_fetch "$PROJ/other-session.jsonl" "2026-11-20T11:00:00.000Z" "u-other-a" "https://app.notion.com/p/$PAGE_A" "OTHER-A"
    # サブディレクトリから起動したセッションは、記録が別の名前の project ディレクトリにある
    mkdir -p "$CFG/projects/-elsewhere-sub"
    put_fetch "$CFG/projects/-elsewhere-sub/sub-session.jsonl" "2026-11-20T09:00:00.000Z" "u-sub-dir" \
        "https://app.notion.com/p/$PAGE_B" "SUBDIR-B"
    # 成功の後に不適格な結果が続いても、成功を採る（後ろの失敗した取得が前の成功を隠さない）
    put_fetch "$now" "2026-11-20T10:00:00.000Z" "u-c-ok" "https://app.notion.com/p/$PAGE_C" "OK-C"
    put_fetch "$now" "2026-11-20T10:01:00.000Z" "u-c-nojson" "https://app.notion.com/p/$PAGE_C" "NOJSON-C" nojson
    put_fetch "$now" "2026-11-20T10:02:00.000Z" "u-c-nocontent" "https://app.notion.com/p/$PAGE_C" "NOCONTENT-C" nocontent
    put_fetch "$now" "2026-11-20T10:03:00.000Z" "u-c-nots" "https://app.notion.com/p/$PAGE_C" "NOTS-C" nots
    # peek 形式の URL（DB の表から開いたページ）。?v= の前は DB の ID で、ページの ID は p=
    put_fetch "$now" "2026-11-20T10:10:00.000Z" "u-peek-e" \
        "https://www.notion.so/ws/$DB_X?v=$VIEW_X&p=$PAGE_E&pm=s" "PEEK-E"
    # 本文が空白だけの結果しか無いページ
    put_fetch "$now" "2026-11-20T10:20:00.000Z" "u-empty-g" "https://app.notion.com/p/$PAGE_G" "EMPTY-G" empty
    # 本文に単独のサロゲートがある（UTF-8 で書けない）
    put_fetch "$now" "2026-11-20T10:40:00.000Z" "u-surr-i" "https://app.notion.com/p/$PAGE_I" "SURR-I" surrogate
    # 本文の中に文字列 </properties> がある
    put_fetch "$now" "2026-11-20T10:30:00.000Z" "u-props-h" "https://app.notion.com/p/$PAGE_H" "PROPS-H" propsclose
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
    out="$(fetch --page "https://app.notion.com/p/$PAGE_A" --session now-session --since 2026-11-20T08:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF --since 以降の同じページがあれば rc=0" 0 "$rc" "$out"
    assert_eq "NF regression: 別セッションの方が新しくても、--session のセッションの新しい方の本文を書く" $'\n# NOW-A2\n\n本文 NOW-A2\nx' "$(cat "$o/body" 2>/dev/null; printf x)"
    assert_eq "NF 属性は <properties> の中身だけを書く" $'\n{"名前":"NOW-A2"}\nx' "$(cat "$o/props" 2>/dev/null; printf x)"

    rm -f "$o"/*
    out="$(fetch --page "${PAGE_A:0:8}-${PAGE_A:8:4}-${PAGE_A:12:4}-${PAGE_A:16:4}-${PAGE_A:20}" --session now-session \
        --since 2026-11-20T09:01:00Z --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF ハイフン付きの ID で引ける" 0 "$rc" "$out"
    assert_eq "NF ハイフン付きの ID で引いた本文" "NOW-A2" "$(sed -n 's/^# //p' "$o/body" 2>/dev/null)"

    rm -f "$o"/*
    # 記録は 09:05:00.250Z、--since は 09:05:00Z。文字列で比べると「.」<「Z」で記録が前に見え、候補から落ちる
    out="$(fetch --page "$PAGE_A" --session now-session --since 2026-11-20T09:05:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF ハイフン無しの ID で引け、時刻は解析して比べる" 0 "$rc" "$out"
    assert_eq "NF 小数秒のある記録を --since と比べて採る" "NOW-A2" "$(sed -n 's/^# //p' "$o/body" 2>/dev/null)"

    rm -f "$o"/*
    out="$(fetch --page "$PAGE_B" --session now-session --since 2026-11-20T00:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF サブエージェントの記録も候補にする" 0 "$rc" "$out"
    assert_eq "NF サブエージェントの記録の本文" "SUB-B" "$(sed -n 's/^# //p' "$o/body" 2>/dev/null)"

    rm -f "$o"/*
    out="$(fetch --page "https://app.notion.com/p/$PAGE_A?pvs=204" --session now-session --since 2026-11-20T08:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF --page に ?pvs= 付きの URL を渡しても引ける" 0 "$rc" "$out"
    assert_eq "NF ?pvs= 付きの URL で引いた本文" "NOW-A2" "$(sed -n 's/^# //p' "$o/body" 2>/dev/null)"

    rm -f "$o"/*
    out="$(fetch --page "$PAGE_D" --session now-session --since 2026-11-20T00:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF 記録の側の ?pvs= 付きの URL も一致とみなす" 0 "$rc" "$out"
    assert_eq "NF 記録の側の ?pvs= 付きの URL の本文" "PVS-D" "$(sed -n 's/^# //p' "$o/body" 2>/dev/null)"

    rm -f "$o"/*
    out="$(fetch --page "$PAGE_A" --session now-session --since 2026-11-20T09:05:00.250Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF 記録の時刻が --since と等しければ採る（境界）" 0 "$rc" "$out"
    assert_eq "NF 等しい時刻の記録の本文" "NOW-A2" "$(sed -n 's/^# //p' "$o/body" 2>/dev/null)"

    rm -rf "$o"/*
    out="$(fetch --page "$PAGE_G" --session now-session --since 2026-11-20T00:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF regression: 本文が空白だけの結果しか無ければ rc=1" 1 "$rc" "$out"
    assert_eq "NF 本文が空のときはどちらも作らない" "" "$(ls "$o")"

    rm -rf "$o"/*
    out="$(fetch --page "https://www.notion.so/ws/$DB_X?v=$VIEW_X&p=$PAGE_E&pm=s" --session now-session \
        --since 2026-11-20T00:00:00Z --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF peek 形式の URL で引ける" 0 "$rc" "$out"
    assert_eq "NF peek 形式の URL で引いた本文" "PEEK-E" "$(sed -n 's/^# //p' "$o/body" 2>/dev/null)"
    rm -rf "$o"/*
    out="$(fetch --page "$PAGE_E" --session now-session --since 2026-11-20T00:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF regression: 記録の側の peek 形式は p= のページ ID で一致させる" 0 "$rc" "$out"
    rm -rf "$o"/*
    out="$(fetch --page "https://www.notion.so/ws/$DB_X?v=$VIEW_X&p=$PAGE_F&pm=s" --session now-session \
        --since 2026-11-20T00:00:00Z --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF regression: 同じ DB の別ページの peek 形式の記録しか無ければ rc=1（DB の ID で一致させない）" 1 "$rc" "$out"
    assert_eq "NF 同じ DB の別ページのときはどちらも作らない" "" "$(ls "$o")"

    rm -rf "$o"/*
    out="$(fetch --page "$PAGE_H" --session now-session --since 2026-11-20T00:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF 本文に </properties> があっても rc=0" 0 "$rc" "$out"
    assert_eq "NF 属性は最初の </properties> までで切る" $'\n{"名前":"PROPS-H"}\nx' "$(cat "$o/props" 2>/dev/null; printf x)"

    rm -rf "$o"/*
    out="$(fetch --page "$PAGE_A" --session now-session --since 2026-11-20T08:00:00Z \
        --out "$o/body" --props-out "$o/nodir/props" 2>&1)"; rc=$?
    assert_rc "NF regression: --props-out の親が無ければ rc=2" 2 "$rc" "$out"
    assert_has "NF 書き込みの失敗のメッセージ" "$out" "notion_fetch_body.py: 書き込めない"
    assert_eq "NF 書き込みの失敗のときは --out も一時ファイルも残さない" "" "$(ls -A "$o")"

    rm -rf "$o"/*
    out="$(fetch --page "$PAGE_I" --session now-session --since 2026-11-20T00:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF regression: 本文を UTF-8 で書けなければ rc=2（rc=1 の候補なしと区別する）" 2 "$rc" "$out"
    assert_eq "NF UTF-8 で書けないときも何も残さない" "" "$(ls -A "$o")"

    # m-4: p= があるのにページ ID として読めなければ、? の前（DB の ID）に落とさない
    rm -rf "$o"/*
    out="$(fetch --page "https://www.notion.so/ws/$DB_X?v=$VIEW_X&p=broken" --session now-session \
        --since 2026-11-20T00:00:00Z --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF regression: p= を読めなければ rc=2（DB の ID で引かない）" 2 "$rc" "$out"
    for q in "p=" "p=&pm=s"; do
        out="$(fetch --page "https://www.notion.so/ws/$DB_X?v=$VIEW_X&$q" --session now-session \
            --since 2026-11-20T00:00:00Z --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
        assert_rc "NF regression: 値が空の $q でも rc=2（DB の ID で引かない）" 2 "$rc" "$out"
    done

    rm -rf "$o"/*
    mkdir -p "$o/adir"
    out="$(fetch --page "$PAGE_A" --session now-session --since 2026-11-20T08:00:00Z \
        --out "$o/body" --props-out "$o/adir" 2>&1)"; rc=$?
    assert_rc "NF regression: 属性の置き換えだけが失敗しても rc=2" 2 "$rc" "$out"
    assert_eq "NF 属性の置き換えだけが失敗したら、置き換えた本文も消す" "adir" "$(ls -A "$o")"
    rm -rf "$o"/*

    rm -f "$o"/*
    out="$(fetch --page "$PAGE_A" --session other-session --since 2026-11-20T08:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF 別のセッションを渡せばそのセッションの結果を採る" 0 "$rc" "$out"
    assert_eq "NF 別のセッションの本文" "OTHER-A" "$(sed -n 's/^# //p' "$o/body" 2>/dev/null)"

    rm -f "$o"/*
    out="$(fetch --page "$PAGE_A" --session old-session --since 2026-11-01T00:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF 過去のセッションを渡せばその記録から採る" 0 "$rc" "$out"
    assert_eq "NF 過去のセッションの本文" "OLD-A" "$(sed -n 's/^# //p' "$o/body" 2>/dev/null)"

    rm -f "$o"/*
    out="$(fetch --page "$PAGE_B" --session sub-session --since 2026-11-20T00:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF regression: 別の名前の project ディレクトリにある今回のセッションの記録も見つける" 0 "$rc" "$out"
    assert_eq "NF 別の project ディレクトリの記録の本文" "SUBDIR-B" "$(sed -n 's/^# //p' "$o/body" 2>/dev/null)"

    rm -f "$o"/*
    out="$(fetch --page "$PAGE_A" --session "" --since 2026-11-20T08:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF セッション ID が空なら rc=1（Write で写す手順へ）" 1 "$rc" "$out"
    assert_has "NF セッション ID が空のときのメッセージ" "$out" "notion_fetch_body.py: セッション ID が無い"
    assert_eq "NF セッション ID が空のときはどちらも作らない" "" "$(ls "$o")"

    rm -f "$o"/*
    out="$(fetch --page "$PAGE_A" --session "../now-session" --since 2026-11-20T08:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF セッション ID が経路を含めば rc=2" 2 "$rc" "$out"
    assert_has "NF セッション ID が経路を含むときのメッセージ" "$out" "notion_fetch_body.py: セッション ID を読めない"

    rm -f "$o"/*
    out="$(fetch --page "$PAGE_A" --session now-session --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF 必須の引数（--since）が無ければ rc=2" 2 "$rc" "$out"
    assert_has "NF 必須の引数が無いときのメッセージ" "$out" "notion_fetch_body.py: 引数の誤り"

    rm -f "$o"/*
    out="$(fetch --page "$PAGE_C" --session now-session --since 2026-11-20T00:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF 成功の後に不適格な結果が続いても rc=0" 0 "$rc" "$out"
    assert_eq "NF JSON でない・<content> の無い・timestamp の無い後ろの結果は採らない" "OK-C" "$(sed -n 's/^# //p' "$o/body" 2>/dev/null)"

    # 負例: 今回（--since 以降）の結果が無く、過去のセッションにだけ同じページの成功結果がある
    rm -f "$o"/*
    out="$(fetch --page "$PAGE_A" --session now-session --since 2026-11-21T00:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF 過去のセッションにしか無ければ rc=1" 1 "$rc" "$out"
    assert_has "NF 候補が無いときのメッセージ" "$out" "notion_fetch_body.py: --since 以降の notion-fetch の結果が無い"
    assert_eq "NF rc=1 のときは --out も --props-out も作らない" "" "$(ls "$o")"

    rm -f "$o"/*
    out="$(fetch --page "0123456789abcdef0123456789abcdef" --session now-session --since 2026-11-01T00:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF 一致するページが無ければ rc=1" 1 "$rc" "$out"
    assert_has "NF 一致するページが無いときのメッセージ" "$out" "notion_fetch_body.py: --since 以降の notion-fetch の結果が無い"

    rm -f "$o"/*
    out="$(fetch --page "not-a-page" --session now-session --since 2026-11-01T00:00:00Z \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF ページ ID を読めなければ rc=2" 2 "$rc" "$out"
    assert_has "NF ページ ID を読めないときのメッセージ" "$out" "notion_fetch_body.py: "

    rm -f "$o"/*
    out="$(fetch --page "$PAGE_A" --session now-session --since "昨日" \
        --out "$o/body" --props-out "$o/props" 2>&1)"; rc=$?
    assert_rc "NF --since を読めなければ rc=2" 2 "$rc" "$out"
    assert_has "NF --since を読めないときのメッセージ" "$out" "notion_fetch_body.py: "
}

# ============================================================ input_guard.py

# 入力が Phase 1 の作り直し（rm -rf <repo>/tmp/adr-review）で消える場所にあるかを判定する。
# 壊れると、レビューを始める前に入力の ADR を消す。ケースごとに 1 条件だけを崩す
run_guard_tests() {
    local out rc g="$WORK/guard"
    rm -rf "$g"
    mkdir -p "$g/repo/docs" "$g/outside/adr-review" "$g/plain/tmp/adr-review" "$g/plain/tmp/adr-review-old" \
        "$g/plain/sub/tmp/adr-review" "$g/notmp"
    printf 'x\n' > "$g/outside/adr-review/draft.md"
    printf 'x\n' > "$g/plain/tmp/adr-review/x.md"
    printf 'x\n' > "$g/plain/tmp/adr-review-old/x.md"
    printf 'x\n' > "$g/plain/sub/tmp/adr-review/x.md"
    printf 'x\n' > "$g/repo/docs/adr.md"
    printf 'x\n' > "$g/notmp/adr.md"
    # repo の tmp が repo の外を指す symlink
    ln -s "$g/outside" "$g/repo/tmp"

    out="$("$PY" "$GUARD" "$g/repo/tmp/adr-review/draft.md" "$g/repo" 2>&1)"; rc=$?
    assert_rc "IG regression: tmp が symlink でも、その下の adr-review/ の入力は止める" 1 "$rc" "$out"
    assert_has "IG 止めるときのメッセージ" "$out" "input_guard.py: 入力が出力の作り直しで消える場所"

    out="$("$PY" "$GUARD" "$g/plain/tmp/adr-review/x.md" "$g/plain" 2>&1)"; rc=$?
    assert_rc "IG 普通の tmp の下の adr-review/ は止める" 1 "$rc" "$out"

    out="$("$PY" "$GUARD" "$g/plain/tmp/adr-review-old/x.md" "$g/plain" 2>&1)"; rc=$?
    assert_rc "IG regression: adr-review-old は止めない（要素単位で比べる）" 0 "$rc" "$out"

    out="$("$PY" "$GUARD" "$g/repo/docs/adr.md" "$g/repo" 2>&1)"; rc=$?
    assert_rc "IG repo の別の場所の ADR は止めない" 0 "$rc" "$out"

    out="$("$PY" "$GUARD" "$g/notmp/adr.md" "$g/notmp" 2>&1)"; rc=$?
    assert_rc "IG tmp が無ければ止めない" 0 "$rc" "$out"

    # 入力は起動時の cwd で解決する。sub/tmp/adr-review/ は toplevel の tmp/adr-review/ ではない
    out="$(cd "$g/plain/sub" && "$PY" "$GUARD" tmp/adr-review/x.md "$g/plain" 2>&1)"; rc=$?
    assert_rc "IG サブディレクトリの相対パスの tmp/adr-review/ は止めない" 0 "$rc" "$out"
    out="$(cd "$g/plain/sub" && "$PY" "$GUARD" ../tmp/adr-review/x.md "$g/plain" 2>&1)"; rc=$?
    assert_rc "IG サブディレクトリからでも toplevel の tmp/adr-review/ を指せば止める" 1 "$rc" "$out"

    # 大文字小文字を区別しないボリューム（macOS の既定）では、綴りを変えた TMP/ADR-REVIEW も同じ場所を指す
    if [[ -e "$g/plain/TMP" ]]; then
        out="$("$PY" "$GUARD" "$g/plain/TMP/ADR-REVIEW/x.md" "$g/plain" 2>&1)"; rc=$?
        assert_rc "IG regression: 大文字小文字を変えた綴りでも、同じ場所なら止める" 1 "$rc" "$out"
    else
        echo "[SKIP] ${LABEL}IG 大文字小文字の綴りのケース（大文字小文字を区別するボリューム）"
    fi

    out="$("$PY" "$GUARD" "$g/repo/docs/none.md" "$g/repo" 2>&1)"; rc=$?
    assert_rc "IG 入力が無ければ rc=2" 2 "$rc" "$out"
    assert_has "IG 入力が無いときのメッセージ" "$out" "input_guard.py: 入力が無い"
    out="$("$PY" "$GUARD" "$g/repo/docs/adr.md" 2>&1)"; rc=$?
    assert_rc "IG 引数が足りなければ rc=2" 2 "$rc" "$out"
    assert_has "IG 引数が足りないときのメッセージ" "$out" "input_guard.py: 使い方"
}

# ============================================================ 実行

PYS=(python3)
if [[ -x /usr/bin/python3 ]] && \
    [[ "$(/usr/bin/python3 -c 'import sys; print(sys.version)')" != "$(python3 -c 'import sys; print(sys.version)')" ]]; then
    PYS+=(/usr/bin/python3)
fi

for f in "$SELECT" "$FETCH" "$GUARD"; do
    [[ -f "$f" ]] || echo "test-review-adr-scripts.sh: 検査対象が見つからない: $f" >&2
done

run_no=0
for PY in "${PYS[@]}"; do
    run_no=$((run_no + 1))
    # mise の shim は cwd で解決先が変わる（cd したサブシェルで別の python になる）ので、実体に固定する
    PY="$("$PY" -c 'import sys; print(sys.executable)')"
    WORK="$BASE/run-$run_no"
    mkdir -p "$WORK"
    LABEL="[$("$PY" -c 'import sys; print("py%d.%d" % sys.version_info[:2])')] "
    echo "== ${PY}（$("$PY" --version 2>&1)）=="
    run_select_tests
    run_select_more_tests
    run_fetch_tests
    run_guard_tests
done

echo
echo "${pass_count} passed / ${fail_count} failed（python: ${PYS[*]}）"
[[ "$fail_count" -eq 0 ]] || exit 1
