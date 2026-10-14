#!/usr/bin/env bash
# series-sync の同期スクリプト（shared/skills/series-sync/scripts/series_sync.py）の挙動テスト。
#
# 同期は他のリポジトリの PR の本文（外部）を書き換える。守りたいのは「目印の外に触れない」
# 「確認の後に変わった本文を上書きしない」「並行の登録を消さない」で、壊れても書き込みは
# 成功して見えるため、通常の動作確認では気づけない。
#
# GitHub には一切つながない。PATH の先頭に偽の gh を置き、書き込み（PATCH）は呼び出しの
# 記録で数える。偽の gh は想定外の引数で非 0 を返す（寛容な偽物だと、実 GitHub が受け付けない
# 呼び方でも全件が通ってしまうため）。
#
# スクリプトは /usr/bin/python3（3.9）でも動かす前提なので、python3 と /usr/bin/python3 が
# 別物なら両方で全件を回す。HOME は差し替えない（mise の shim が壊れるため）。
#
# 起動: bash shared/scripts/tests/test-series-sync.sh

# set -e は使わない。1 件目の失敗で残りが走らなくなると、Red で全件の失敗を確かめられない
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SYNC="$REPO_ROOT/shared/skills/series-sync/scripts/series_sync.py"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass_count=0
fail_count=0
LABEL=""

pass() { echo -e "${GREEN}[PASS]${NC} ${LABEL}$1"; pass_count=$((pass_count + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} ${LABEL}$1"; fail_count=$((fail_count + 1)); }

# python ごとの回で WORK を分ける（前の回が作った plan の DIR が残ると、-2 の判定が狂う）
BASE="$(mktemp -d)"
WORK="$BASE"
cleanup() { rm -rf "$BASE"; }
trap cleanup EXIT

# ============================================================ 共通の道具

# 期待どおりの終了コードか
assert_rc() {  # $1=名前 $2=期待 $3=実際 $4=出力（失敗時に見せる）
    if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1（rc=$3、期待 $2）: ${4:0:400}"; fi
}

assert_has() {  # $1=名前 $2=出力 $3=含むべき文字列
    if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1（「$3」が無い）: ${2:0:400}"; fi
}

assert_not_has() {  # $1=名前 $2=出力 $3=含まないはずの文字列
    if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1（「$3」がある）: ${2:0:400}"; fi
}

assert_same_file() {  # $1=名前 $2=期待のファイル $3=実際のファイル
    if cmp -s "$2" "$3"; then pass "$1"; else fail "$1: $(diff "$2" "$3" | head -12)"; fi
}

ss() { "$PY" "$SYNC" "$@"; }

# ------------------------------------------------------------ fixture
# 3 段・2 リポジトリ（契約の正典 series-format.md の例と同じ形）。
# @APR@ などを sed で置き換えて、段ごとの登録の状態を作る
cat >"$BASE/series.tmpl" <<'EOF'
---
type: Series
title: 注文の取込の改善
outline: /abs/outline/tmp/plan.md
branch_prefix: feat/order-import-
timestamp: 2026-01-01T10:00:00+09:00
---

# シリーズ: 注文の取込の改善

## 段

| 段 | リポジトリ | 含むステップ | base | 順序 | worktree | ブランチ | PR |
|----|-----------|-------------|------|------|----------|---------|----|
| A | acme/api | S-1・S-2 | develop | 1 | /wt/api-a | @ABR@ | @APR@ |
| B | acme/api | S-3 | 段 A に積む | 2 | /wt/api-a | @BBR@ | @BPR@ |
| C | acme/web | S-4 | main | 3 | @CWT@ | @CBR@ | @CPR@ |

## 強調

| 段 | ノード |
|----|--------|
| A | VALID, RECV |
| B | SAVE |
| C | NOTIFY |

## 全体像

````markdown
## 🗺️ 全体像（注文の取込の改善）

**この PR（{{this}}）が担う部分を黄色で示しています。** 灰色は同じシリーズの別の PR、点線はシリーズの外です。

```mermaid
flowchart LR
  SRC["取引先のファイル置き場"]
  RECV["{{num:A}} ファイルを受ける<br/>（取引先ごとに分ける）"]
  VALID["{{num:A}} 形式を検証する"]
  SAVE["{{num:B}} 注文を保存する"]
  NOTIFY["{{num:C}} 取込結果を通知する"]
  SRC --> RECV --> VALID --> SAVE --> NOTIFY
  classDef cur fill:#ffe082,stroke:#f57f17,stroke-width:3px,color:#000
  classDef other fill:#eceff1,stroke:#90a4ae,color:#455a64
  classDef ext fill:#ffffff,stroke:#bdbdbd,stroke-dasharray:4 3,color:#616161
  {{classes}}
  class SRC ext
```

| | PR | リポジトリ | 領域 | 直すもの | 解決する事象 | 順序 |
|---|---|---|---|---|---|---|
| {{mark:A}} | {{prcell:A}} | api | 受付・検証 | 受付 | 取りこぼし | 1 |
| {{mark:B}} | {{prcell:B}} | api | 保存 | 保存 | 重複 | 2（{{pr:A}} に積む） |
| {{mark:C}} | {{prcell:C}} | web | 通知 | 通知 | 通知漏れ | 3 |

- 順序の理由: 受付が先
- このシリーズの外: なし
````

## 進捗

<!-- series-sync status が GitHub から実測して書き換える。手で編集しない -->

## メモ

手で書いたメモ
EOF

# $1=出力先 $2..: A の PR・B の PR・C の PR（空なら未登録）。ブランチは PR があるときだけ埋める
mk_series() {
    local out="$1" apr="${2:-}" bpr="${3:-}" cpr="${4:-}"
    local abr="" bbr="" cbr="" cwt=""
    [[ -n "$apr" ]] && abr="feat/order-import-recv"
    [[ -n "$bpr" ]] && bbr="feat/order-import-save"
    [[ -n "$cpr" ]] && { cbr="feat/order-import-notify"; cwt="/wt/web-c"; }
    sed -e "s|@APR@|$apr|" -e "s|@BPR@|$bpr|" -e "s|@CPR@|$cpr|" \
        -e "s|@ABR@|$abr|" -e "s|@BBR@|$bbr|" -e "s|@CBR@|$cbr|" -e "s|@CWT@|$cwt|" \
        "$BASE/series.tmpl" >"$out"
}


# 壊した fixture を作る。置き換え前と後の組を 1 つ以上受ける（python で置き換える。sed だと
# 日本語と記号の扱いが割れる）。置き換え前の文字列が無ければ非 0（壊したつもりで壊れていない
# fixture で「error が出ない」を見落とさないため）
mutate() {  # $1=元 $2=出力 $3=前 $4=後 [$5=前 $6=後 …]
    "$PY" - "$@" <<'PYEOF'
import sys
src, dst = sys.argv[1:3]
pairs = sys.argv[3:]
text = open(src, encoding="utf-8").read()
for old, new in zip(pairs[0::2], pairs[1::2]):
    if old not in text:
        sys.exit("mutate: 置き換え前の文字列が無い: " + old)
    text = text.replace(old, new, 1)
open(dst, "w", encoding="utf-8").write(text)
PYEOF
}

# ============================================================ SS-1: check（C-1）

check_case() {  # $1=名前 $2=error 行に含まれる語 $3..=mutate の組
    local name="$1" want="$2" out rc
    shift 2
    if ! mutate "$WORK/c-base.md" "$WORK/c-bad.md" "$@" 2>"$WORK/mutate.err"; then
        fail "SS-1 ${name}: fixture を壊せない（$(cat "$WORK/mutate.err")）"
        return
    fi
    out="$(ss check "$WORK/c-bad.md" 2>&1)"; rc=$?
    if [[ "$rc" == 1 && "$out" == *"error: "*"$want"* ]]; then
        pass "SS-1 ${name} → exit 1 と error"
    else
        fail "SS-1 ${name}（rc=${rc}、「${want}」を期待）: ${out:0:300}"
    fi
}

run_check_tests() {
    local out rc
    mk_series "$WORK/c-base.md" 12 "" 5
    out="$(ss check "$WORK/c-base.md" 2>&1)"; rc=$?
    if [[ "$rc" == 0 && -z "$out" ]]; then
        pass "SS-1 正しい series.md は exit 0 で何も出さない"
    else
        fail "SS-1 正しい series.md（rc=${rc}）: ${out:0:300}"
    fi

    check_case "未知の置換子" "未知の置換子" "{{this}}" "{{thiss}}"
    check_case "存在しない段を指す置換子" "存在しない段" "{{num:B}} 注文" "{{num:Z}} 注文"
    check_case "強調のノードが mermaid に無い" "定義されていない" "| B | SAVE |" "| B | SAVEX |"
    check_case "1 つのノードが 2 つの段にある" "2 つの段" "| C | NOTIFY |" "| C | NOTIFY, SAVE |"
    check_case "mark の無い段がある（表に載らない PR）" "表に載らない" "| {{mark:C}} |" "| |"
    check_case "完成形にステップ ID がある" "内部 ID" "- 順序の理由: 受付が先" "- 順序の理由: S-1 が先"
    check_case "段名の文法違反" "段名が文法" "| C | acme/web |" "| C! | acme/web |" \
        "| C | NOTIFY |" "| C! | NOTIFY |" "{{mark:C}}" "{{mark:C!}}"
    check_case "classes が 0 個" "{{classes}} の行が 1 つでない" "  {{classes}}" "  %% none"
    check_case "classes が 2 個" "{{classes}} の行が 1 つでない" "  class SRC ext" "  {{classes}}"
    check_case "classes が行の途中にもある" "行の途中" "  class SRC ext" "  class SRC ext %% {{classes}}"
    check_case "完成形に目印の文字列がある" "目印の文字列" \
        "- このシリーズの外: なし" "- このシリーズの外: <!-- series-overview:end -->"
    check_case "完成形の先頭が全体像の見出しでない" "全体像 で始まらない" \
        "## 🗺️ 全体像（注文の取込の改善）" "## 概要"
    check_case "frontmatter に outline が無い" "outline が無い" "outline: /abs/outline/tmp/plan.md" "owner: x"
    check_case "強調のノードが辺の行の中でだけ定義されている" "定義されていない" \
        $'  NOTIFY["{{num:C}} 取込結果を通知する"]\n' "" \
        "--> SAVE --> NOTIFY" '--> SAVE --> NOTIFY["{{num:C}} 取込結果を通知する"]'
    # plan.md のステップは「### ステップ N:」なので、含むステップは数字で書かれる
    check_case "完成形にステップ番号がある（含むステップが数字）" "内部 ID" \
        "| A | acme/api | S-1・S-2 |" "| A | acme/api | 1・2 |" \
        "- 順序の理由: 受付が先" "- 順序の理由: ステップ 2 が先"
    check_case "完成形にステップ番号がある（含むステップがステップ N）" "内部 ID" \
        "| A | acme/api | S-1・S-2 |" "| A | acme/api | ステップ 1・ステップ 2 |" \
        "- 順序の理由: 受付が先" "- 順序の理由: ステップ1 が先"
    check_case "強調の行が無い段がある" "強調" $'| C | NOTIFY |\n' ""
    check_case "強調のノードが空の段がある" "強調" "| C | NOTIFY |" "| C | |"
    check_case "同じ PR が 2 つの段にある" "acme/api#12" "| 2 | /wt/api-a |  |  |" "| 2 | /wt/api-a | x | 12 |"
    # 余分なセルは書き直しで消えるので、書き直す前に止める
    check_case "段の行のセルが見出しより多い" "見出しより多い: 段 B" \
        "| 2 | /wt/api-a |  |  |" "| 2 | /wt/api-a |  |  | EXTRA |"
    # 列の並びは問わないので、段名は「段」の列から取る（段の列が先頭でない表）
    check_case "段の列が先頭でない表で、セルの多い行の段名を出す" "見出しより多い: 段 A" \
        "| 段 | リポジトリ |" "| リポジトリ | 段 |" \
        "| A | acme/api | S-1・S-2 | develop | 1 | /wt/api-a | feat/order-import-recv | 12 |" \
        "| acme/api | A | S-1・S-2 | develop | 1 | /wt/api-a | feat/order-import-recv | 12 | EXTRA |" \
        "| B | acme/api |" "| acme/api | B |" "| C | acme/web |" "| acme/web | C |"

    # 数字だけの語（PR 番号・順序の列）や、別の番号のステップでは止めない
    check_ok_case "含むステップが数字でも、完成形の数字だけには当てない" \
        "| A | acme/api | S-1・S-2 |" "| A | acme/api | 1・2 |"
    check_ok_case "ステップ 1 に対して ステップ 12 は当てない" \
        "| A | acme/api | S-1・S-2 |" "| A | acme/api | 1 |" \
        "- 順序の理由: 受付が先" "- 順序の理由: ステップ 12 が先"
}

check_ok_case() {  # $1=名前 $2..=mutate の組。壊した後も exit 0 で何も出さない
    local name="$1" out rc
    shift
    if ! mutate "$WORK/c-base.md" "$WORK/c-ok.md" "$@" 2>"$WORK/mutate.err"; then
        fail "SS-1 ${name}: fixture を変えられない（$(cat "$WORK/mutate.err")）"
        return
    fi
    out="$(ss check "$WORK/c-ok.md" 2>&1)"; rc=$?
    if [[ "$rc" == 0 && -z "$out" ]]; then
        pass "SS-1 ${name} → exit 0"
    else
        fail "SS-1 ${name}（rc=${rc}）: ${out:0:300}"
    fi
}

# ============================================================ SS-2: render（ブロック。C-2・C-3）

# 期待値はリテラルで書く（render の出力から作ると、全段で同じ誤りを見逃すため）
run_render_block_tests() {
    local s="$WORK/r.md" a b c out rc
    mk_series "$s" 12 13 5
    a="$(ss render "$s" --stage A 2>&1)"; rc=$?
    assert_rc "SS-2 render --stage A は exit 0" 0 "$rc" "$a"
    b="$(ss render "$s" --stage B 2>&1)"
    c="$(ss render "$s" --stage C 2>&1)"

    assert_has "SS-2 ブロックは begin の目印で始まる" "${a%%$'\n'*}" "<!-- series-overview:begin -->"
    assert_has "SS-2 ブロックは --- と end の目印で終わる" "$a" $'\n\n---\n<!-- series-overview:end -->'
    assert_has "SS-2 A の凡例は #12" "$a" "**この PR（#12）が担う部分を黄色で示しています。**"
    # 強調の表に「VALID, RECV」と逆順・空白つきで書いても、定義順・空白なしになる
    assert_has "SS-2 A の cur は定義順・空白なし（字下げを引き継ぐ）" "$a" $'\n  class RECV,VALID cur\n'
    assert_has "SS-2 A の other は他の段のノード" "$a" $'\n  class SAVE,NOTIFY other\n'
    assert_has "SS-2 A の表は A の行だけ 👉 と太字" "$a" "| 👉 | **#12** | api | 受付・検証 |"
    assert_has "SS-2 A から見た B は同じリポジトリの #13" "$a" "|  | #13 | api | 保存 |"
    assert_has "SS-2 A から見た C は表で owner/repo#N" "$a" "|  | acme/web#5 | web | 通知 |"
    assert_has "SS-2 A から見た C はラベルで repo#N" "$a" 'NOTIFY["web#5 取込結果を通知する"]'
    assert_has "SS-2 A から見た A のラベルは #12" "$a" 'RECV["#12 ファイルを受ける'
    assert_has "SS-2 C から見た A は表で owner/repo#N" "$c" "|  | acme/api#12 | api | 受付・検証 |"
    assert_has "SS-2 C から見た A のラベルは repo#N" "$c" 'RECV["api#12 ファイルを受ける'
    assert_has "SS-2 C から見た積む先の参照も owner/repo#N" "$c" "2（acme/api#12 に積む）"
    assert_has "SS-2 C の cur は NOTIFY" "$c" $'\n  class NOTIFY cur\n'
    if [[ "$b" == "<!-- series-overview:begin -->"* && "$c" == "<!-- series-overview:begin -->"* \
        && "$a$b$c" != *"{{"* ]]; then
        pass "SS-2 置換子が残らない（3 段）"
    else
        fail "SS-2 置換子が残るか、描画できない段がある"
    fi

    # どの 2 段の組でも、違いは凡例・class 2 行・表の 2 行・別リポジトリの参照の書き方だけ（D-9）
    local x y dx dy diffs
    for pair in "A B" "A C" "B C"; do
        x="${pair% *}"; y="${pair#* }"
        ss render "$s" --stage "$x" >"$WORK/r-$x.txt"
        ss render "$s" --stage "$y" >"$WORK/r-$y.txt"
        # 別リポジトリの参照の書き方を揃えてから比べる
        for f in "$WORK/r-$x.txt" "$WORK/r-$y.txt"; do
            sed -E -e 's#acme/(api|web)\##\##g' -e 's#(^|[^A-Za-z/])(api|web)\##\1\##g' "$f" >"$f.norm"
        done
        diffs="$(diff "$WORK/r-$x.txt.norm" "$WORK/r-$y.txt.norm" | grep -E '^[<>] ')"
        local bad
        bad="$(printf '%s\n' "$diffs" | grep -vE '^[<>] (\*\*この PR（|  class [A-Z,]+ (cur|other)$|\| (👉)? +\| )')"
        if [[ -z "$bad" && "$(printf '%s\n' "$diffs" | grep -c .)" == 10 ]]; then
            pass "SS-2 段 ${x} と ${y} の違いは凡例・class 2 行・表 2 行だけ（10 行）"
        else
            fail "SS-2 段 ${x} と ${y} の違いが想定の外: $(printf '%s\n' "$diffs" | head -14)"
        fi
    done

    # 未登録の段
    mk_series "$s" 12 "" ""
    out="$(ss render "$s" --stage B 2>&1)"
    assert_has "SS-2 未登録の段の凡例は（未作成）" "$out" "**この PR（（未作成））が"
    assert_has "SS-2 未登録の段は表で（未作成）" "$out" "| 👉 | （未作成） | api | 保存 |"
    assert_has "SS-2 未登録の段はラベルで 未作成" "$out" 'SAVE["未作成 注文を保存する"]'

    out="$(ss render "$s" --stage Z 2>&1)"; rc=$?
    assert_rc "SS-2 存在しない段の render は exit 1" 1 "$rc" "$out"
    out="$(ss check "$WORK/no-such.md" 2>&1)"; rc=$?
    if [[ "$rc" == 1 && "$out" == "error: "* ]]; then
        pass "SS-2 series.md が無ければ exit 1 と error:（traceback にしない）"
    else
        fail "SS-2 series.md が無いとき（rc=${rc}）: ${out:0:200}"
    fi
}

# ============================================================ SS-3: render（本文に当てる。C-4）

BODY_TAIL=$'## 📝 PR 概要 📝\n\n- **目的**: 本文\n\n## 👮‍♂️ 動作確認 👮‍♂️\n\n- [x] 末尾の空白  \n'

run_render_body_tests() {
    local s="$WORK/b.md" block out rc
    mk_series "$s" 12 13 5
    ss render "$s" --stage A >"$WORK/block.txt"
    block="$(cat "$WORK/block.txt")"   # 末尾の改行を落とした形
    # ブロックが空だと「空の本文」や冪等のケースが空どうしの一致で通ってしまう
    if [[ "$block" != "<!-- series-overview:begin -->"* ]]; then
        fail "SS-3 ブロックを描画できない（以降の本文のケースを飛ばす）"
        return
    fi

    # 目印あり → 目印の外がバイト単位で同じ
    printf 'ref XX-1\n\n<!-- series-overview:begin -->\n古い\n<!-- series-overview:end -->\n\n%s' "$BODY_TAIL" >"$WORK/b1.md"
    ss render "$s" --stage A --body-file "$WORK/b1.md" >"$WORK/b1.out"; rc=$?
    assert_rc "SS-3 目印ありの本文は exit 0" 0 "$rc" "$(cat "$WORK/b1.out")"
    { printf 'ref XX-1\n\n%s\n\n%s' "$block" "$BODY_TAIL"; } >"$WORK/b1.exp"
    assert_same_file "SS-3 目印ありは目印の間だけが替わる（外はバイト単位で同じ）" "$WORK/b1.exp" "$WORK/b1.out"

    # 目印も見出しも無い → 先頭に入る
    printf '%s' "$BODY_TAIL" >"$WORK/b2.md"
    ss render "$s" --stage A --body-file "$WORK/b2.md" >"$WORK/b2.out"
    { printf '%s\n\n%s' "$block" "$BODY_TAIL"; } >"$WORK/b2.exp"
    assert_same_file "SS-3 目印も見出しも無ければ先頭に入る" "$WORK/b2.exp" "$WORK/b2.out"

    # 1 行目が ref → ref 行と空行の後に入る
    printf 'ref XX-1\n\n%s' "$BODY_TAIL" >"$WORK/b3.md"
    ss render "$s" --stage A --body-file "$WORK/b3.md" >"$WORK/b3.out"
    { printf 'ref XX-1\n\n%s\n\n%s' "$block" "$BODY_TAIL"; } >"$WORK/b3.exp"
    assert_same_file "SS-3 1 行目が ref なら ref 行と空行の後に入る" "$WORK/b3.exp" "$WORK/b3.out"

    # 空の本文 → ブロックだけ
    : >"$WORK/b4.md"
    ss render "$s" --stage A --body-file "$WORK/b4.md" >"$WORK/b4.out"
    printf '%s' "$block" >"$WORK/b4.exp"
    assert_same_file "SS-3 空の本文はブロックだけの本文になる" "$WORK/b4.exp" "$WORK/b4.out"

    # 見出しだけ → --migrate 無しでは error（fail-closed）
    printf '## 🗺️ 全体像（古い）\n\n古い図\n\n---\n%s' "$BODY_TAIL" >"$WORK/b5.md"
    out="$(ss render "$s" --stage A --body-file "$WORK/b5.md" 2>&1)"; rc=$?
    assert_rc "SS-3 見出しだけの本文は --migrate 無しで exit 1" 1 "$rc" "$out"
    assert_has "SS-3 見出しだけの理由は heading-only:" "$out" "heading-only:"

    # 異体字セレクタの無い見出しも同じ扱い
    printf '## \xf0\x9f\x97\xba 全体像（古い）\n\n---\n%s' "$BODY_TAIL" >"$WORK/b5b.md"
    out="$(ss render "$s" --stage A --body-file "$WORK/b5b.md" 2>&1)"; rc=$?
    assert_rc "SS-3 U+FE0F の無い見出しも heading-only で exit 1" 1 "$rc" "$out"

    # 同じで --migrate → 見出し〜最初の --- が置き換わり、後ろは同じ
    ss render "$s" --stage A --body-file "$WORK/b5.md" --migrate >"$WORK/b6.out"; rc=$?
    assert_rc "SS-3 --migrate は exit 0" 0 "$rc" "$(cat "$WORK/b6.out")"
    { printf '%s\n%s' "$block" "$BODY_TAIL"; } >"$WORK/b6.exp"
    assert_same_file "SS-3 --migrate は見出し〜最初の --- だけを置き換える" "$WORK/b6.exp" "$WORK/b6.out"

    # --migrate で間に別の ## がある → error（PR 概要まで消さない）
    printf '## 🗺️ 全体像（古い）\n\n古い図\n\n%s\n---\n' "$BODY_TAIL" >"$WORK/b7.md"
    out="$(ss render "$s" --stage A --body-file "$WORK/b7.md" --migrate 2>&1)"; rc=$?
    assert_rc "SS-3 --migrate で間に別の ## があれば exit 1" 1 "$rc" "$out"
    assert_has "SS-3 その理由は migrate:" "$out" "migrate:"

    # 目印が片方だけ・2 組・逆順 → markers:
    local name body
    for name in "begin だけ" "2 組" "逆順"; do
        case "$name" in
            "begin だけ") body=$'<!-- series-overview:begin -->\n古い\n' ;;
            "2 組") body=$'<!-- series-overview:begin -->\n<!-- series-overview:end -->\n<!-- series-overview:begin -->\n<!-- series-overview:end -->\n' ;;
            "逆順") body=$'<!-- series-overview:end -->\n<!-- series-overview:begin -->\n' ;;
        esac
        printf '%s%s' "$body" "$BODY_TAIL" >"$WORK/b8.md"
        out="$(ss render "$s" --stage A --body-file "$WORK/b8.md" --migrate 2>&1)"; rc=$?
        if [[ "$rc" == 1 && "$out" == *"markers:"* ]]; then
            pass "SS-3 目印が ${name} → exit 1 と markers:（--migrate でも）"
        else
            fail "SS-3 目印が ${name}（rc=${rc}）: ${out:0:200}"
        fi
    done

    # CRLF の本文 → CRLF のまま（ブロックも CRLF）
    printf 'ref XX-1\r\n\r\n## 📝 PR 概要 📝\r\n本文\r\n' >"$WORK/b9.md"
    ss render "$s" --stage A --body-file "$WORK/b9.md" >"$WORK/b9.out"
    { printf 'ref XX-1\n\n%s\n\n## 📝 PR 概要 📝\n本文\n' "$block"; } | "$PY" -c \
        'import sys; d=sys.stdin.buffer.read(); sys.stdout.buffer.write(d.replace(b"\n", b"\r\n"))' >"$WORK/b9.exp"
    assert_same_file "SS-3 CRLF の本文は CRLF のまま" "$WORK/b9.exp" "$WORK/b9.out"

    # 冪等: 出力にもう一度当てても同じ
    local f
    for f in b1 b2 b3 b4 b6 b9; do
        ss render "$s" --stage A --body-file "$WORK/$f.out" >"$WORK/$f.again"
        if ! cmp -s "$WORK/$f.out" "$WORK/$f.again"; then
            fail "SS-3 冪等でない: $f"
            return
        fi
    done
    pass "SS-3 出力にもう一度当てても同じ（冪等。6 種）"
}

# ============================================================ 偽の gh

# 状態は $FAKE_GH_DIR の JSON から返し、呼び出しを 1 行ずつ calls.log に残す。
#   pulls/<o>__<r>__<n>.json   REST の PR（GET が返し、PATCH が body を書き戻す）
#   graphql/<o>__<r>__<n>.json GraphQL の応答
#   list/<o>__<r>.json         pr list の候補（--search は絞らずに全件を返す。実 GitHub の
#                              head: 検索は前方一致より広く当たるので、スクリプトの絞り直しを通すため）
# FAKE_GH_CORRUPT_PATCH=1     PATCH の書き戻しで本文の末尾 1 字を落とす（読み直しの不一致）
# FAKE_GH_EDIT_BEFORE_PATCH=1 GET に別の本文を返す（plan の後に誰かが本文を変えた）
FAKE_BIN="$BASE/fakebin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/gh" <<'FAKEGH'
#!/usr/bin/env python3
import json, os, re, sys
d = os.environ["FAKE_GH_DIR"]
a = sys.argv[1:]
with open(os.path.join(d, "calls.log"), "a", encoding="utf-8") as f:
    f.write(" ".join(a) + "\n")

def die(msg):
    sys.stderr.write("fake gh: " + msg + "\n")
    sys.exit(2)

def read(rel):
    p = os.path.join(d, rel)
    if not os.path.exists(p):
        die("no such fixture: " + rel)
    with open(p, encoding="utf-8") as f:
        return json.load(f)

def key(path):
    m = re.match(r"^repos/([^/]+)/([^/]+)/pulls/([0-9]+)$", path)
    if not m:
        die("bad path: " + path)
    return "%s__%s__%s" % m.groups()

if len(a) == 2 and a[0] == "api":
    pull = read("pulls/%s.json" % key(a[1]))
    if os.environ.get("FAKE_GH_EDIT_BEFORE_PATCH") == "1":
        pull["body"] = (pull.get("body") or "") + "\n（誰かが編集した）"
    print(json.dumps(pull, ensure_ascii=False))
elif len(a) == 6 and a[:3] == ["api", "-X", "PATCH"] and a[4] == "--input":
    k = key(a[3])
    with open(a[5], encoding="utf-8") as f:
        body = json.load(f)["body"]
    if os.environ.get("FAKE_GH_CORRUPT_PATCH") == "1":
        body = body[:-1]
    pull = read("pulls/%s.json" % k)
    pull["body"] = body
    with open(os.path.join(d, "pulls/%s.json" % k), "w", encoding="utf-8") as f:
        json.dump(pull, f, ensure_ascii=False)
    print(json.dumps(pull, ensure_ascii=False))
elif len(a) == 10 and a[:2] == ["api", "graphql"] and a[2::2] == ["-f", "-f", "-f", "-F"] \
        and a[3].startswith("query=") and "reviewThreads" in a[3] \
        and a[5].startswith("o=") and a[7].startswith("r=") and re.match(r"^n=[0-9]+$", a[9]):
    print(json.dumps(read("graphql/%s__%s__%s.json" % (a[5][2:], a[7][2:], a[9][2:]))))
elif len(a) == 12 and a[:3] == ["pr", "list", "-R"] and a[4] == "--search" \
        and a[5].startswith("head:") and a[6:] == ["--state", "all", "--json",
                                                   "number,headRefName", "--limit", "100"]:
    print(json.dumps(read("list/%s.json" % a[3].replace("/", "__"))))
elif len(a) == 10 and a[:3] == ["pr", "list", "-R"] and a[4] == "--head" \
        and a[6:] == ["--state", "all", "--json", "number"]:
    items = read("list/%s.json" % a[3].replace("/", "__"))
    print(json.dumps([{"number": p["number"]} for p in items if p["headRefName"] == a[5]]))
else:
    die("unexpected args: " + " ".join(a))
FAKEGH
chmod +x "$FAKE_BIN/gh"

# 偽の gh の環境を作り直す
gh_reset() {
    export FAKE_GH_DIR="$WORK/gh"
    rm -rf "$FAKE_GH_DIR"
    mkdir -p "$FAKE_GH_DIR/pulls" "$FAKE_GH_DIR/graphql" "$FAKE_GH_DIR/list"
    : >"$FAKE_GH_DIR/calls.log"
    unset FAKE_GH_CORRUPT_PATCH FAKE_GH_EDIT_BEFORE_PATCH
}

# $1=owner/repo $2=番号 $3=state（open|closed） $4=draft（true|false） $5=merged_at（null か日時）
# $6=本文のファイル（"null" なら body: null）
mk_pull() {
    "$PY" - "$FAKE_GH_DIR" "$@" <<'PYEOF'
import json, sys
d, repo, n, state, draft, merged, body = sys.argv[1:8]
o, r = repo.split("/")
text = None if body == "null" else open(body, encoding="utf-8", newline="").read()
pull = {"number": int(n), "state": state, "draft": draft == "true",
        "merged_at": None if merged == "null" else merged, "body": text,
        "head": {"ref": "x"}}
json.dump(pull, open("%s/pulls/%s__%s__%s.json" % (d, o, r, n), "w", encoding="utf-8"),
          ensure_ascii=False)
PYEOF
}

pull_body() {  # $1=owner/repo $2=番号 → 本文を標準出力へ（そのままのバイトで）
    "$PY" - "$FAKE_GH_DIR" "$1" "$2" <<'PYEOF'
import json, sys
d, repo, n = sys.argv[1:4]
o, r = repo.split("/")
body = json.load(open("%s/pulls/%s__%s__%s.json" % (d, o, r, n), encoding="utf-8"))["body"]
sys.stdout.buffer.write((body or "").encode("utf-8"))
PYEOF
}

patch_count() { grep -c -- '-X PATCH' "$FAKE_GH_DIR/calls.log"; }

# 節「## 進捗」の本文と timestamp の行を除いた残り（status が外を変えないことの比較用）
outside_progress() {
    "$PY" - "$1" <<'PYEOF'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
text = re.sub(r"(?m)^timestamp: .*$", "timestamp: -", text)
text = re.sub(r"(?s)(\n## 進捗\n).*?(\n## メモ\n)", r"\1\2", text)
sys.stdout.write(text)
PYEOF
}

# ロックを持つ子プロセスを起動し、取れたことを確かめてから戻る。$1=series.md $2=持つ秒数
# ロックを持っている間に、別の書き手として段 B に PR #13 を登録する。登録は書き手が起動して
# ロックの外で読み終えた後（2.5 秒後。書き手の生存の確認は約 1 秒後）に書く。先に書くと、ロックの外で読む書き手にも見えてしまい、
# 「読み直さない」回帰を区別できない
LOCK_PID=""
CONCURRENT_ROW="| B | acme/api | S-3 | 段 A に積む | 2 | /wt/api-a | feat/order-import-save | 13 |"
hold_lock() {
    rm -f "$WORK/lock.ready"
    "$PY" -c '
import fcntl, re, sys, time
f = open(sys.argv[1] + ".lock", "a")
fcntl.flock(f, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(2.5)
text = open(sys.argv[1], encoding="utf-8").read()
text = re.sub(r"(?m)^\| B \| acme/api \|.*$", lambda m: sys.argv[4], text, count=1)
open(sys.argv[1], "w", encoding="utf-8").write(text)
time.sleep(float(sys.argv[3]) - 2.5)
' "$1" "$WORK/lock.ready" "$2" "$CONCURRENT_ROW" &
    LOCK_PID=$!
    local i
    for i in $(seq 1 50); do
        [[ -f "$WORK/lock.ready" ]] && return 0
        sleep 0.1
    done
    return 1
}

# ロックの中で読み直して書くことを確かめる。$1=名前 $2=series.md $3..=スクリプトの引数
# 「書き手がまだ走っていなかった」だけで通らないよう、ロックを持つ間に書き手が生きていることを条件にし、
# ロックを持つ間に入った別の登録が、書き手の書き込みの後も残っていることを確かめる
assert_waits_for_lock() {
    local name="$1" s="$2" pid rc
    shift 2
    if ! hold_lock "$s" 4; then
        fail "${name}: ロックを取る子プロセスが起動しない"
        return
    fi
    cp "$s" "$WORK/lock.before"
    ss "$@" >"$WORK/lock.out" 2>&1 &
    pid=$!
    sleep 1
    if kill -0 "$pid" 2>/dev/null && cmp -s "$WORK/lock.before" "$s"; then
        pass "${name}: ロックを持つ間は書かずに待つ"
    else
        fail "${name}: ロックを待たずに書いた（$(cat "$WORK/lock.out")）"
    fi
    wait "$LOCK_PID"
    wait "$pid"; rc=$?
    # 書いた中身は呼び出し側が確かめる（hold_lock 自身も書くので、ここで前後を比べても意味が無い）
    if [[ "$rc" == 0 ]]; then
        pass "${name}: ロックが外れた後に exit 0 で終わる"
    else
        fail "${name}: ロックが外れた後（rc=${rc}）: $(cat "$WORK/lock.out")"
    fi
    if grep -qF -- "$CONCURRENT_ROW" "$s"; then
        pass "${name}: ロックを持つ間に入った別の登録を消さない（ロックの中で読み直す）"
    else
        fail "${name}: ロックを持つ間に入った段 B の登録が消えた"
    fi
}

# ============================================================ SS-4: register（C-5・C-6）

run_register_tests() {
    local s="$WORK/reg.md" out rc
    # ブランチの一致で決まる（同じリポジトリに PR の空いた段 B があっても A に入る）
    mk_series "$WORK/reg0.md" 12 "" ""
    mutate "$WORK/reg0.md" "$s" "| feat/order-import-recv | 12 |" "| feat/order-import-recv |  |"
    out="$(ss register "$s" --repo acme/api --branch feat/order-import-recv --pr 12 2>&1)"; rc=$?
    assert_rc "SS-4 ブランチの一致で段が決まる" 0 "$rc" "$out"
    assert_has "SS-4 ブランチの一致 → 段 A に登録" "$(cat "$s")" "| A | acme/api | S-1・S-2 | develop | 1 | /wt/api-a | feat/order-import-recv | 12 |"
    assert_has "SS-4 registered: を出す" "$out" "registered: 段 A acme/api#12"

    # 同じ値でもう一度 → unchanged でバイトが変わらない
    cp "$s" "$WORK/reg.before"
    out="$(ss register "$s" --repo acme/api --branch feat/order-import-recv --pr 12 2>&1)"; rc=$?
    assert_rc "SS-4 同じ値の再登録は exit 0" 0 "$rc" "$out"
    assert_has "SS-4 同じ値の再登録は unchanged:" "$out" "unchanged: 段 A"
    if [[ "$rc" == 0 && "$out" == *"unchanged:"* ]] && cmp -s "$WORK/reg.before" "$s"; then
        pass "SS-4 同じ値の再登録は series.md を変えない"
    else
        fail "SS-4 同じ値の再登録で series.md が変わった（rc=${rc}）"
    fi

    # worktree の一致で決まる
    mk_series "$WORK/reg0.md" "" "" ""
    mutate "$WORK/reg0.md" "$s" "| 2 | /wt/api-a |" "| 2 | /wt/api-b |"
    out="$(ss register "$s" --repo acme/api --branch feat/order-import-save --pr 13 --worktree /wt/api-b 2>&1)"; rc=$?
    assert_rc "SS-4 worktree の一致で段が決まる" 0 "$rc" "$out"
    assert_has "SS-4 worktree の一致 → 段 B" "$(cat "$s")" "| B | acme/api | S-3 | 段 A に積む | 2 | /wt/api-b | feat/order-import-save | 13 |"

    # リポジトリで 1 行に決まる。worktree が空なら埋める
    mk_series "$s" "" "" ""
    out="$(ss register "$s" --repo acme/web --branch feat/order-import-notify --pr 5 --worktree /wt/web-c 2>&1)"; rc=$?
    assert_rc "SS-4 リポジトリで 1 行に決まる" 0 "$rc" "$out"
    assert_has "SS-4 リポジトリの一致 → 段 C（worktree も埋まる）" "$(cat "$s")" "| C | acme/web | S-4 | main | 3 | /wt/web-c | feat/order-import-notify | 5 |"

    # 2 行の候補 → exit 3 と候補の一覧（series.md は変わらない）
    mk_series "$s" "" "" ""
    cp "$s" "$WORK/reg.before"
    out="$(ss register "$s" --repo acme/api --branch feat/order-import-x --pr 30 2>&1)"; rc=$?
    assert_rc "SS-4 候補が 2 行なら exit 3" 3 "$rc" "$out"
    if [[ "$out" == *"候補"* && "$out" == *"  A acme/api"* && "$out" == *"  B acme/api"* ]]; then
        pass "SS-4 候補が 2 行なら A と B を出す"
    else
        fail "SS-4 候補の一覧: ${out:0:300}"
    fi
    if [[ "$rc" == 3 ]] && cmp -s "$WORK/reg.before" "$s"; then
        pass "SS-4 曖昧なときは series.md を変えない"
    else
        fail "SS-4 曖昧なとき（rc=${rc}）に series.md が変わったか、exit 3 でない"
    fi

    # PR 列が別の番号 → exit 3（衝突）
    mk_series "$s" 12 "" ""
    cp "$s" "$WORK/reg.before"
    out="$(ss register "$s" --stage A --repo acme/api --branch feat/order-import-recv --pr 99 2>&1)"; rc=$?
    assert_rc "SS-4 段の PR が別の番号なら exit 3" 3 "$rc" "$out"
    if [[ "$rc" == 3 ]] && cmp -s "$WORK/reg.before" "$s"; then
        pass "SS-4 衝突のときは series.md を変えない"
    else
        fail "SS-4 衝突のとき（rc=${rc}）に series.md が変わったか、exit 3 でない"
    fi

    # --stage の段のリポジトリが違う → exit 3
    cp "$s" "$WORK/reg.before"
    out="$(ss register "$s" --stage C --repo acme/api --branch feat/order-import-x --pr 40 2>&1)"; rc=$?
    if [[ "$rc" == 3 ]] && cmp -s "$WORK/reg.before" "$s"; then
        pass "SS-4 --stage の段のリポジトリが違えば exit 3 で series.md を変えない"
    else
        fail "SS-4 --stage の段のリポジトリ違い（rc=${rc}）"
    fi

    # 候補が 0 行（リポジトリの行がすべて別の PR で埋まっている）
    mk_series "$s" 12 13 ""
    out="$(ss register "$s" --repo acme/api --branch feat/order-import-x --pr 40 2>&1)"; rc=$?
    assert_rc "SS-4 候補が 0 行なら exit 3" 3 "$rc" "$out"
    assert_has "SS-4 候補が 0 行なら「候補なし」" "$out" "候補なし"

    # ロックの中で読み直して書く（並行の登録を消さない）
    mk_series "$s" "" "" ""
    assert_waits_for_lock "SS-4 register" "$s" register "$s" --repo acme/web --branch feat/order-import-notify --pr 5
    assert_has "SS-4 ロックの後の register は段 C に書く" "$(cat "$s")" "| feat/order-import-notify | 5 |"
}

# ============================================================ SS-5: write（C-7）

run_write_tests() {
    local s="$WORK/w.md" f="$WORK/w-draft.md" out rc
    # 今の series.md: 段 A・C に PR、進捗とメモに内容がある
    mk_series "$WORK/w0.md" 12 "" 5
    mutate "$WORK/w0.md" "$s" "<!-- series-sync status が GitHub から実測して書き換える。手で編集しない -->" \
        "<!-- series-sync status が GitHub から実測して書き換える。手で編集しない -->"$'\n\n'"取得: 前回の進捗"
    # 下書き: ブランチ・PR・worktree が空、メモは別の内容
    mk_series "$WORK/w1.md" "" "" ""
    mutate "$WORK/w1.md" "$f" "手で書いたメモ" "下書きのメモ" "直すもの | 解決する事象" "直すもの | 解決する事象（新）"
    out="$(ss write "$s" --from "$f" 2>&1)"; rc=$?
    assert_rc "SS-5 空の下書きの write は exit 0" 0 "$rc" "$out"
    local now; now="$(cat "$s")"
    # 下書きが書かれていなければ、引き継ぎの確認は「元のまま」で空振りする
    if [[ "$rc" != 0 || "$now" != *"解決する事象（新）"* ]]; then
        fail "SS-5 下書きが書かれていない（引き継ぎのケースを飛ばす）"
    else
    pass "SS-5 下書きの構成が入る"
    assert_has "SS-5 段 A のブランチ・PR を引き継ぐ" "$now" "| A | acme/api | S-1・S-2 | develop | 1 | /wt/api-a | feat/order-import-recv | 12 |"
    assert_has "SS-5 段 C のブランチ・PR を引き継ぎ、worktree は下書きの空を書く" "$now" "| C | acme/web | S-4 | main | 3 |  | feat/order-import-notify | 5 |"
    assert_has "SS-5 引き継いだ列に worktree を含めない" "$out" "inherited: C（ブランチ・PR）"
    assert_has "SS-5 進捗を引き継ぐ" "$now" "取得: 前回の進捗"
    assert_has "SS-5 メモを引き継ぐ" "$now" "手で書いたメモ"
    assert_not_has "SS-5 下書きのメモで上書きしない" "$now" "下書きのメモ"
    assert_has "SS-5 引き継いだ段を出す" "$out" "inherited: C"
    fi

    # 下書きに無い段に PR が登録済み → exit 3、series.md は変わらない
    mk_series "$s" 12 "" ""
    mk_series "$WORK/w1.md" "" "" ""
    mutate "$WORK/w1.md" "$f" "| A | acme/api |" "| A2 | acme/api |" "| A | VALID, RECV |" "| A2 | VALID, RECV |" \
        "{{num:A}} ファイル" "{{num:A2}} ファイル" "{{num:A}} 形式" "{{num:A2}} 形式" \
        "{{mark:A}} | {{prcell:A}}" "{{mark:A2}} | {{prcell:A2}}" "{{pr:A}} に積む" "{{pr:A2}} に積む"
    out="$(ss check "$f" 2>&1)"; rc=$?
    assert_rc "SS-5 段名を変えた下書きは check を通る（前提）" 0 "$rc" "$out"
    cp "$s" "$WORK/w.before"
    out="$(ss write "$s" --from "$f" 2>&1)"; rc=$?
    assert_rc "SS-5 下書きに無い段に PR が登録済みなら exit 3" 3 "$rc" "$out"
    assert_has "SS-5 その段と PR を出す" "$out" "A acme/api#12"
    if [[ "$rc" == 3 ]] && cmp -s "$WORK/w.before" "$s"; then pass "SS-5 exit 3 のときは series.md を変えない"; else fail "SS-5 下書きに無い段（rc=${rc}）で series.md が変わったか exit 3 でない"; fi

    # --drop に別の段だけ → exit 3 のまま
    out="$(ss write "$s" --from "$f" --drop B 2>&1)"; rc=$?
    assert_rc "SS-5 --drop に別の段だけなら exit 3 のまま" 3 "$rc" "$out"
    if [[ "$rc" == 3 ]] && cmp -s "$WORK/w.before" "$s"; then pass "SS-5 --drop が外れていれば series.md を変えない"; else fail "SS-5 --drop が外れている（rc=${rc}）"; fi

    # --drop <その段> → exit 0、dropped:、段が消える
    out="$(ss write "$s" --from "$f" --drop A 2>&1)"; rc=$?
    assert_rc "SS-5 --drop A なら exit 0" 0 "$rc" "$out"
    assert_has "SS-5 外した PR を dropped: で出す" "$out" "dropped: A acme/api#12"
    if ! grep -q '^| A | acme/api' "$s" && grep -q '^| A2 | acme/api' "$s"; then
        pass "SS-5 --drop の後は段 A が消え、A2 になる"
    else
        fail "SS-5 --drop の後の段: $(grep -E '^\| A2? \| acme/api' "$s")"
    fi

    # 下書きのブランチ・PR が今の値と違う → exit 3
    mk_series "$s" 12 "" ""
    mk_series "$f" 99 "" ""
    cp "$s" "$WORK/w.before"
    out="$(ss write "$s" --from "$f" 2>&1)"; rc=$?
    assert_rc "SS-5 下書きの PR が今の値と違えば exit 3" 3 "$rc" "$out"
    if [[ "$rc" == 3 ]] && cmp -s "$WORK/w.before" "$s"; then pass "SS-5 値が違うときは series.md を変えない"; else fail "SS-5 値が違う（rc=${rc}）"; fi

    # 初回（series.md が無い）→ 下書きのとおりに書き、ロックファイルができる
    rm -f "$WORK/w-new.md" "$WORK/w-new.md.lock"
    mk_series "$f" "" "" ""
    out="$(ss write "$WORK/w-new.md" --from "$f" 2>&1)"; rc=$?
    assert_rc "SS-5 初回の write は exit 0" 0 "$rc" "$out"
    assert_same_file "SS-5 初回は下書きのとおりに書く" "$f" "$WORK/w-new.md"
    if [[ -f "$WORK/w-new.md.lock" ]]; then pass "SS-5 初回もロックファイルができる"; else fail "SS-5 初回にロックファイルが無い"; fi

    # check を通らない下書き → exit 1、series.md は変わらない
    mk_series "$s" 12 "" ""
    mutate "$s" "$f" "{{this}}" "{{thiss}}"
    cp "$s" "$WORK/w.before"
    out="$(ss write "$s" --from "$f" 2>&1)"; rc=$?
    assert_rc "SS-5 check を通らない下書きは exit 1" 1 "$rc" "$out"
    if [[ "$rc" == 1 && "$out" == *"error: "* ]] && cmp -s "$WORK/w.before" "$s"; then pass "SS-5 check を通らない下書きでは series.md を変えない"; else fail "SS-5 check を通らない下書き（rc=${rc}）"; fi

    # ロック: ロックを持つ間は待ち、外れた後に引き継いで書く
    mk_series "$s" 12 "" ""
    mk_series "$WORK/w1.md" "" "" ""
    mutate "$WORK/w1.md" "$f" "直すもの | 解決する事象" "直すもの | 解決する事象（新）"
    assert_waits_for_lock "SS-5 write" "$s" write "$s" --from "$f"
    if grep -q '解決する事象（新）' "$s" && grep -q '| feat/order-import-recv | 12 |' "$s"; then
        pass "SS-5 ロックの後の write は登録を引き継いで書く"
    else
        fail "SS-5 ロックの後の write の内容: $(grep '^| A ' "$s")"
    fi
}

# ============================================================ SS-6: status（C-8）

run_status_tests() {
    local s="$WORK/st.md" out rc
    gh_reset
    mk_series "$WORK/st0.md" 12 13 ""
    # 段 C はブランチ列だけがある（PR はまだ登録されていない）
    mutate "$WORK/st0.md" "$s" "| 3 |  |  |  |" "| 3 |  | feat/order-import-notify |  |"
    cat >"$FAKE_GH_DIR/graphql/acme__api__12.json" <<'EOF'
{"data":{"repository":{"pullRequest":{"state":"MERGED","isDraft":false,"mergedAt":"2026-01-02T03:04:05Z","headRefName":"feat/order-import-recv","baseRefName":"develop","reviewDecision":"APPROVED","reviewThreads":{"totalCount":3,"nodes":[{"isResolved":false},{"isResolved":true},{"isResolved":false}]}}}}}
EOF
    cat >"$FAKE_GH_DIR/graphql/acme__api__13.json" <<'EOF'
{"data":{"repository":{"pullRequest":{"state":"OPEN","isDraft":true,"mergedAt":null,"headRefName":"feat/order-import-save-x","baseRefName":"feat/order-import-recv","reviewDecision":null,"reviewThreads":{"totalCount":0,"nodes":[]}}}}}
EOF
    cat >"$FAKE_GH_DIR/list/acme__api.json" <<'EOF'
[{"number":12,"headRefName":"feat/order-import-recv"},{"number":13,"headRefName":"feat/order-import-save-x"},
 {"number":14,"headRefName":"feat/order-import-extra"},{"number":15,"headRefName":"feature/order-import-other"}]
EOF
    cat >"$FAKE_GH_DIR/list/acme__web.json" <<'EOF'
[{"number":21,"headRefName":"feat/order-import-notify"}]
EOF
    cp "$s" "$WORK/st.before"
    out="$(PATH="$FAKE_BIN:$PATH" ss status "$s" 2>&1)"; rc=$?
    assert_rc "SS-6 status は exit 0" 0 "$rc" "$out"
    local now; now="$(cat "$s")"
    assert_has "SS-6 merged の日付・APPROVED・未解決 2" "$now" "| A | acme/api | #12 | merged（2026-01-02） | APPROVED | 2 | feat/order-import-recv |"
    assert_has "SS-6 draft・レビューなし・未解決 0" "$now" "| B | acme/api | #13 | draft | — | 0 | feat/order-import-save-x |"
    assert_has "SS-6 未登録の段は 未作成" "$now" "| C | acme/web | — | 未作成 | — | — | feat/order-import-notify |"
    assert_not_has "SS-6 timestamp を更新する" "$now" "timestamp: 2026-01-01T10:00:00+09:00"
    if [[ "$rc" == 0 && "$now" == *"| A | acme/api | #12 |"* ]] \
        && [[ "$(outside_progress "$WORK/st.before")" == "$(outside_progress "$s")" ]]; then
        pass "SS-6 ## 進捗 と timestamp の外は変わらない"
    else
        fail "SS-6 ## 進捗 の外が変わった"
    fi
    assert_has "SS-6 接頭辞に当たる未登録の PR を warning" "$out" "warning: 段に未登録の PR: acme/api#14"
    if [[ "$out" == *"acme/api#14"* && "$out" != *"#15"* ]]; then
        pass "SS-6 接頭辞に当たらないブランチ（feature/…）は warning にしない"
    else
        fail "SS-6 接頭辞の絞り直し: ${out:0:300}"
    fi
    assert_has "SS-6 ブランチ列があって PR が空の段の PR を warning" "$out" "段 C のブランチ feat/order-import-notify に未登録の PR acme/web#21"
    assert_has "SS-6 ブランチ列と PR のブランチの違いを warning" "$out" "warning: 段 B のブランチ列"
    if [[ "$rc" == 0 && -s "$FAKE_GH_DIR/calls.log" && "$(patch_count)" == 0 ]]; then pass "SS-6 status は GitHub を読み、PATCH しない"; else fail "SS-6 status が PATCH したか、GitHub を読んでいない"; fi

    # ロックの中で読み直して ## 進捗 を書く（並行の登録を消さない）
    mk_series "$WORK/st-lock.md" 12 "" ""
    : >"$FAKE_GH_DIR/calls.log"
    # pass・fail の数を数えるため、サブシェルにせず PATH をこの呼び出しの間だけ差し替える
    local saved_path="$PATH"
    PATH="$FAKE_BIN:$PATH"
    assert_waits_for_lock "SS-6 status" "$WORK/st-lock.md" status "$WORK/st-lock.md"
    PATH="$saved_path"
    assert_has "SS-6 ロックの後の status は ## 進捗 を書く" "$(cat "$WORK/st-lock.md")" "| A | acme/api | #12 | merged（2026-01-02）"

    # GitHub が PR を返さない（番号の誤り）→ exit 1
    cp "$s" "$WORK/st.before"
    echo '{"data":{"repository":{"pullRequest":null}}}' >"$FAKE_GH_DIR/graphql/acme__api__13.json"
    out="$(PATH="$FAKE_BIN:$PATH" ss status "$s" 2>&1)"; rc=$?
    if [[ "$rc" == 1 && "$out" == *"error: "*"acme/api#13"* ]] && cmp -s "$WORK/st.before" "$s"; then
        pass "SS-6 PR が見つからなければ exit 1 と error:（series.md は変えない）"
    else
        fail "SS-6 PR が見つからないとき（rc=${rc}）: ${out:0:200}"
    fi

    # GitHub の読み取りに失敗 → exit 1、series.md は変わらない
    cp "$s" "$WORK/st.before"
    rm "$FAKE_GH_DIR/graphql/acme__api__13.json"
    out="$(PATH="$FAKE_BIN:$PATH" ss status "$s" 2>&1)"; rc=$?
    assert_rc "SS-6 GitHub の読み取りに失敗したら exit 1" 1 "$rc" "$out"
    if [[ "$rc" == 1 && "$out" == *"error: "* ]] && cmp -s "$WORK/st.before" "$s"; then pass "SS-6 失敗のときは series.md を変えない"; else fail "SS-6 失敗のとき（rc=${rc}）"; fi
}

# ============================================================ SS-7: plan（C-9）・SS-8: apply（C-10）

# A（merged）・B（open）・C（open）を登録した series.md と、C を登録する前の描画を持つ本文を作る
setup_sync() {
    gh_reset
    mk_series "$WORK/sync-old.md" 12 13 ""
    mk_series "$WORK/sync.md" 12 13 5
    ss render "$WORK/sync-old.md" --stage A >"$WORK/old-a.txt"
    ss render "$WORK/sync-old.md" --stage B >"$WORK/old-b.txt"
    { printf 'ref XX-1\n\n'; cat "$WORK/old-a.txt"; printf '\n%s' "$BODY_TAIL"; } >"$WORK/body-a.md"
    { cat "$WORK/old-b.txt"; printf '\n%s' "$BODY_TAIL"; } >"$WORK/body-b.md"
    mk_pull acme/api 12 closed false 2026-01-02T03:04:05Z "$WORK/body-a.md"
    mk_pull acme/api 13 open true null "$WORK/body-b.md"
    mk_pull acme/web 5 open false null null
}

run_plan_tests() {
    local s="$WORK/sync.md" out rc dir
    setup_sync
    out="$(PATH="$FAKE_BIN:$PATH" ss plan "$s" --out "$WORK/plan1" 2>&1)"; rc=$?
    assert_rc "SS-7 plan は exit 0" 0 "$rc" "$out"
    assert_has "SS-7 マージ済みの PR も対象（replace）" "$out" "acme/api#12 merged replace"
    assert_has "SS-7 open の PR は replace" "$out" "acme/api#13 draft replace"
    assert_has "SS-7 body: null の PR は insert" "$out" "acme/web#5 open insert"
    assert_has "SS-7 件数" "$out" "changes: 3 / errors: 0"
    if [[ -f "$WORK/plan1/plan.json" && -f "$WORK/plan1/acme__api__12.before.md" && -f "$WORK/plan1/acme__web__5.after.md" ]]; then
        pass "SS-7 plan.json と before・after を書く"
    else
        fail "SS-7 plan の DIR の中身: $(ls "$WORK/plan1" 2>&1)"
    fi
    assert_has "SS-7 新しい段 C が A の表に owner/repo#N で載る（AC-3）" "$(cat "$WORK/plan1/acme__api__12.after.md")" "|  | acme/web#5 | web | 通知 |"
    assert_same_file "SS-7 before は GitHub の本文のまま" "$WORK/body-a.md" "$WORK/plan1/acme__api__12.before.md"
    if [[ "$rc" == 0 && "$(patch_count)" == 0 ]] && grep -q '^api repos/acme/web/pulls/5$' "$FAKE_GH_DIR/calls.log"; then pass "SS-7 plan は GET だけで PATCH しない"; else fail "SS-7 plan が PATCH したか、GET していない"; fi

    # 同じ --out でもう一度 → -2 の DIR に書く（前の before を上書きしない）
    out="$(PATH="$FAKE_BIN:$PATH" ss plan "$s" --out "$WORK/plan1" 2>&1)"
    assert_has "SS-7 同じ DIR が既にあれば -2 を付ける" "$out" "dir: $WORK/plan1-2"
    # --out 無し → series.md の隣の series-sync/<日時>/
    out="$(PATH="$FAKE_BIN:$PATH" ss plan "$s" 2>&1)"
    if [[ "$out" =~ dir:\ $WORK/series-sync/[0-9]{8}-[0-9]{6}(-[0-9]+)?$'\n'?$ ]]; then
        pass "SS-7 --out 無しは series.md の隣の series-sync/<日時>/"
    else
        fail "SS-7 既定の DIR: ${out##*dir: }"
    fi

    # 本文がすでに描画と同じ → none（AC-15 の前半）
    gh_reset
    mk_pull acme/api 12 closed false 2026-01-02T03:04:05Z "$WORK/plan1/acme__api__12.after.md"
    mk_pull acme/api 13 open true null "$WORK/plan1/acme__api__13.after.md"
    mk_pull acme/web 5 open false null "$WORK/plan1/acme__web__5.after.md"
    out="$(PATH="$FAKE_BIN:$PATH" ss plan "$s" --out "$WORK/plan-none" 2>&1)"; rc=$?
    assert_rc "SS-7 変わらない plan は exit 0" 0 "$rc" "$out"
    assert_has "SS-7 変わらない plan は changes: 0" "$out" "changes: 0 / errors: 0"
    assert_has "SS-7 変わらない PR は none" "$out" "acme/api#12 merged none"

    # error の分類（本文の当て方の網羅は SS-3。ここは理由の受け渡しを代表 1 件ずつ）
    gh_reset
    printf '## 🗺️ 全体像（古い）\n\n---\n%s' "$BODY_TAIL" >"$WORK/body-h.md"
    printf '<!-- series-overview:begin -->\n%s' "$BODY_TAIL" >"$WORK/body-m.md"
    "$PY" -c 'import sys; sys.stdout.write("x" * 70000)' >"$WORK/body-l.md"
    mk_pull acme/api 12 closed false 2026-01-02T03:04:05Z "$WORK/body-h.md"
    mk_pull acme/api 13 open false null "$WORK/body-m.md"
    mk_pull acme/web 5 open false null "$WORK/body-l.md"
    out="$(PATH="$FAKE_BIN:$PATH" ss plan "$s" --out "$WORK/plan-err" 2>&1)"; rc=$?
    assert_rc "SS-7 error の PR があれば exit 1" 1 "$rc" "$out"
    assert_has "SS-7 見出しだけは error heading-only:" "$out" "acme/api#12 merged error heading-only:"
    assert_has "SS-7 目印の不整合は error markers:" "$out" "acme/api#13 open error markers:"
    assert_has "SS-7 65,536 字を超えれば error" "$out" "acme/web#5 open error too-long:"
    out="$(PATH="$FAKE_BIN:$PATH" ss plan "$s" --out "$WORK/plan-mig" --migrate 2>&1)"
    assert_has "SS-7 --migrate では見出しだけの PR が migrate" "$out" "acme/api#12 merged migrate"

    # check が失敗する series.md → exit 1 で何も書かない
    mutate "$s" "$WORK/sync-bad.md" "{{this}}" "{{thiss}}"
    : >"$FAKE_GH_DIR/calls.log"
    out="$(PATH="$FAKE_BIN:$PATH" ss plan "$WORK/sync-bad.md" --out "$WORK/plan-bad" 2>&1)"; rc=$?
    assert_rc "SS-7 check が失敗する series.md の plan は exit 1" 1 "$rc" "$out"
    if [[ "$rc" == 1 && "$out" == *"error: "* && ! -e "$WORK/plan-bad" && ! -s "$FAKE_GH_DIR/calls.log" ]]; then
        pass "SS-7 check が失敗したら DIR を作らず GitHub も読まない"
    else
        fail "SS-7 check が失敗したのに書いた・読んだ"
    fi
}

run_apply_tests() {
    local s="$WORK/sync.md" out rc dir
    setup_sync
    PATH="$FAKE_BIN:$PATH" ss plan "$s" --out "$WORK/ap1" >/dev/null 2>&1
    out="$(PATH="$FAKE_BIN:$PATH" ss apply --plan "$WORK/ap1" 2>&1)"; rc=$?
    assert_rc "SS-8 apply は exit 0" 0 "$rc" "$out"
    assert_has "SS-8 written を出す" "$out" "written: acme/web#5"
    if [[ "$(patch_count)" == 3 ]]; then pass "SS-8 change の 3 本だけ PATCH する"; else fail "SS-8 PATCH の回数: $(patch_count)"; fi
    pull_body acme/api 12 >"$WORK/ap1.now"
    assert_same_file "SS-8 書いた本文は after と同じ" "$WORK/ap1/acme__api__12.after.md" "$WORK/ap1.now"
    assert_has "SS-8 PATCH は DIR の patch.json を --input で渡す" "$(cat "$FAKE_GH_DIR/calls.log")" \
        "api -X PATCH repos/acme/api/pulls/12 --input $WORK/ap1/acme__api__12.patch.json"
    "$PY" -c 'import json,sys; sys.stdout.write(json.load(open(sys.argv[1], encoding="utf-8"))["body"])' \
        "$WORK/ap1/acme__api__12.patch.json" >"$WORK/ap1.patch"
    assert_same_file "SS-8 patch.json の body は after と同じ" "$WORK/ap1/acme__api__12.after.md" "$WORK/ap1.patch"
    # 書いた後のブロックの外は元の本文と同じ（AC-5）
    { printf 'ref XX-1\n\n'; ss render "$s" --stage A; printf '\n%s' "$BODY_TAIL"; } >"$WORK/ap1.exp"
    assert_same_file "SS-8 書いた本文はブロックだけが替わり、外は元のまま" "$WORK/ap1.exp" "$WORK/ap1.now"

    # 変更の無い plan → PATCH 0 回（AC-15）
    : >"$FAKE_GH_DIR/calls.log"
    PATH="$FAKE_BIN:$PATH" ss plan "$s" --out "$WORK/ap-none" >/dev/null 2>&1
    out="$(PATH="$FAKE_BIN:$PATH" ss apply --plan "$WORK/ap-none" 2>&1)"; rc=$?
    assert_rc "SS-8 変わらない plan の apply は exit 0" 0 "$rc" "$out"
    if [[ "$rc" == 0 && "$(patch_count)" == 0 ]] && grep -q '^api repos/acme/web/pulls/5$' "$FAKE_GH_DIR/calls.log"; then pass "SS-8 変わらない同期は PATCH 0 回"; else fail "SS-8 変わらない同期で PATCH したか、plan が走っていない"; fi

    # none の PR は、plan の後に本文が変わっても触らない（書く対象でないので skipped にもしない）
    : >"$FAKE_GH_DIR/calls.log"
    out="$(FAKE_GH_EDIT_BEFORE_PATCH=1 PATH="$FAKE_BIN:$PATH" ss apply --plan "$WORK/ap-none" 2>&1)"; rc=$?
    if [[ "$rc" == 0 && -z "$out" && ! -s "$FAKE_GH_DIR/calls.log" ]]; then
        pass "SS-8 none の PR は plan の後に変わっても読まず・書かず・skipped にしない"
    else
        fail "SS-8 none の PR に触れた（rc=${rc}）: ${out:0:200}"
    fi

    # plan の後に本文が変わった → skipped で書かない（AC-16）
    setup_sync
    PATH="$FAKE_BIN:$PATH" ss plan "$s" --out "$WORK/ap2" >/dev/null 2>&1
    out="$(FAKE_GH_EDIT_BEFORE_PATCH=1 PATH="$FAKE_BIN:$PATH" ss apply --plan "$WORK/ap2" 2>&1)"; rc=$?
    assert_rc "SS-8 plan の後に変わった本文があれば exit 1" 1 "$rc" "$out"
    assert_has "SS-8 その PR は skipped" "$out" "skipped: acme/api#12"
    if [[ "$out" == *"skipped:"* && "$(patch_count)" == 0 ]]; then pass "SS-8 skipped の PR には PATCH しない"; else fail "SS-8 skipped なのに PATCH した"; fi

    # 書き込み後の読み直しが一致しない → mismatch（AC-17）
    setup_sync
    PATH="$FAKE_BIN:$PATH" ss plan "$s" --out "$WORK/ap3" >/dev/null 2>&1
    out="$(FAKE_GH_CORRUPT_PATCH=1 PATH="$FAKE_BIN:$PATH" ss apply --plan "$WORK/ap3" 2>&1)"; rc=$?
    assert_rc "SS-8 読み直しが一致しなければ exit 1" 1 "$rc" "$out"
    assert_has "SS-8 その PR は mismatch" "$out" "mismatch: acme/api#12"

    # --only は指定の 1 本だけ。やり直しの全体 apply では、その 1 本は unchanged
    setup_sync
    PATH="$FAKE_BIN:$PATH" ss plan "$s" --out "$WORK/ap4" >/dev/null 2>&1
    out="$(PATH="$FAKE_BIN:$PATH" ss apply --plan "$WORK/ap4" --only acme/web#5 2>&1)"; rc=$?
    assert_rc "SS-8 --only は exit 0" 0 "$rc" "$out"
    if [[ "$(patch_count)" == 1 ]] && grep -q 'PATCH repos/acme/web/pulls/5 ' "$FAKE_GH_DIR/calls.log"; then
        pass "SS-8 --only は指定の 1 本だけ PATCH する"
    else
        fail "SS-8 --only の PATCH: $(grep PATCH "$FAKE_GH_DIR/calls.log")"
    fi
    out="$(PATH="$FAKE_BIN:$PATH" ss apply --plan "$WORK/ap4" 2>&1)"; rc=$?
    assert_rc "SS-8 やり直しの apply は exit 0" 0 "$rc" "$out"
    assert_has "SS-8 書き終えた 1 本は unchanged" "$out" "unchanged: acme/web#5"
    if [[ "$(patch_count)" == 3 && "$out" == *"written: acme/api#12"* && "$out" == *"written: acme/api#13"* ]]; then
        pass "SS-8 やり直しでは残りの 2 本だけを書く（二重に書かない）"
    else
        fail "SS-8 やり直しの PATCH の回数: $(patch_count)"
    fi

    out="$(PATH="$FAKE_BIN:$PATH" ss apply --plan "$WORK/no-such-plan" 2>&1)"; rc=$?
    if [[ "$rc" == 1 && "$out" == "error: "* ]]; then pass "SS-8 plan の DIR が無ければ exit 1 と error:"; else fail "SS-8 plan の DIR が無いとき（rc=${rc}）: ${out:0:200}"; fi

    # plan に無い PR の --only → exit 1、PATCH 0 回
    setup_sync
    PATH="$FAKE_BIN:$PATH" ss plan "$s" --out "$WORK/ap5" >/dev/null 2>&1
    out="$(PATH="$FAKE_BIN:$PATH" ss apply --plan "$WORK/ap5" --only acme/web#999 2>&1)"; rc=$?
    assert_rc "SS-8 plan に無い PR の --only は exit 1" 1 "$rc" "$out"
    if [[ "$rc" == 1 && "$out" == *"plan に無い PR"* && "$(patch_count)" == 0 ]]; then pass "SS-8 plan に無い PR の --only では PATCH しない"; else fail "SS-8 plan に無い PR の --only（rc=${rc}）"; fi
}

# ============================================================ SS-9: 全体レビューの指摘（regression）

run_review_regression_tests() {
    local s="$WORK/rv.md" f="$WORK/rv-draft.md" out rc
    # R-1 下書きの worktree は今の値と違っても書く（worktree 列は series-init の持ち分）
    mk_series "$s" 12 "" ""
    mk_series "$WORK/rv0.md" "" "" ""
    mutate "$WORK/rv0.md" "$f" "| 1 | /wt/api-a |" "| 1 | /wt/api-new |"
    out="$(ss write "$s" --from "$f" 2>&1)"; rc=$?
    if [[ "$rc" == 0 ]] && grep -qF '| A | acme/api | S-1・S-2 | develop | 1 | /wt/api-new | feat/order-import-recv | 12 |' "$s"; then
        pass "SS-9 regression: 下書きの worktree は今の値と違っても書き、ブランチ・PR は引き継ぐ"
    else
        fail "SS-9 regression: 下書きの worktree（rc=${rc}）: ${out:0:200}"
    fi

    # R-2 ## 進捗 の節が無ければ check で止める
    mk_series "$WORK/rv1.md" 12 "" ""
    mutate "$WORK/rv1.md" "$WORK/rv-noprog.md" "## 進捗"$'\n' ""
    out="$(ss check "$WORK/rv-noprog.md" 2>&1)"; rc=$?
    if [[ "$rc" == 1 && "$out" == *"## 進捗"* ]]; then pass "SS-9 regression: ## 進捗 が無ければ check が error"; else fail "SS-9 regression: ## 進捗 が無い（rc=${rc}）: ${out:0:200}"; fi

    # R-4 段のリポジトリを変えた下書きは、登録済みの PR を別リポジトリへ引き継がない
    mk_series "$s" 12 "" ""
    mk_series "$WORK/rv0.md" "" "" ""
    mutate "$WORK/rv0.md" "$f" "| A | acme/api |" "| A | acme/other |"
    cp "$s" "$WORK/rv.before"
    out="$(ss write "$s" --from "$f" 2>&1)"; rc=$?
    if [[ "$rc" == 3 ]] && cmp -s "$WORK/rv.before" "$s"; then pass "SS-9 regression: リポジトリを変えた段に PR があれば exit 3"; else fail "SS-9 regression: リポジトリを変えた段（rc=${rc}）: ${out:0:200}"; fi

    # R-5 register は表を壊す値を拒否する
    mk_series "$s" "" "" ""
    cp "$s" "$WORK/rv.before"
    out="$(ss register "$s" --repo acme/web --branch 'feat/x|y' --pr 5 2>&1)"; rc=$?
    if [[ "$rc" == 1 ]] && cmp -s "$WORK/rv.before" "$s"; then pass "SS-9 regression: | を含むブランチの register は exit 1"; else fail "SS-9 regression: | を含むブランチ（rc=${rc}）"; fi
    out="$(ss register "$s" --repo 'acme web' --branch feat/x --pr 5 2>&1)"; rc=$?
    assert_rc "SS-9 regression: owner/repo でない --repo は exit 1" 1 "$rc" "$out"

    # R-10 同じ PR を 2 つの段に登録しない
    mk_series "$s" 12 "" ""
    cp "$s" "$WORK/rv.before"
    out="$(ss register "$s" --stage B --repo acme/api --branch feat/order-import-save --pr 12 2>&1)"; rc=$?
    if [[ "$rc" == 3 ]] && cmp -s "$WORK/rv.before" "$s"; then pass "SS-9 regression: 別の段に登録済みの PR は exit 3"; else fail "SS-9 regression: 同じ PR を 2 段に（rc=${rc}）"; fi

    # R-6 本文のコードの囲みの中の目印・見出しは数えない
    mk_series "$s" 12 13 5
    ss render "$s" --stage A >"$WORK/rv-block.txt"
    printf '<!-- series-overview:begin -->\n古い\n<!-- series-overview:end -->\n\n```\n<!-- series-overview:begin -->\n## 🗺️ 例\n```\n' >"$WORK/rv-fence.md"
    ss render "$s" --stage A --body-file "$WORK/rv-fence.md" >"$WORK/rv-fence.out" 2>&1; rc=$?
    { cat "$WORK/rv-block.txt"; printf '\n```\n<!-- series-overview:begin -->\n## 🗺️ 例\n```\n'; } >"$WORK/rv-fence.exp"
    if [[ "$rc" == 0 ]] && cmp -s "$WORK/rv-fence.exp" "$WORK/rv-fence.out"; then pass "SS-9 regression: コードの囲みの中の目印は数えない"; else fail "SS-9 regression: 囲みの中の目印（rc=${rc}）: $(head -3 "$WORK/rv-fence.out")"; fi

    # R-7 LF と CRLF が混ざった本文で、目印の外の行末を変えない
    printf 'ref XX-1\r\n\r\n## 📝 PR 概要 📝\n本文\n' >"$WORK/rv-mixed.md"
    ss render "$s" --stage A --body-file "$WORK/rv-mixed.md" >"$WORK/rv-mixed.out"
    # 外の行は元の行末のまま、足したブロックと区切りの空行は CRLF（本文に CRLF があるため）
    { printf 'ref XX-1\r\n\r\n'; "$PY" -c 'import sys; d=open(sys.argv[1],"rb").read().rstrip(b"\n"); sys.stdout.buffer.write(d.replace(b"\n", b"\r\n") + b"\r\n\r\n")' "$WORK/rv-block.txt"; printf '## 📝 PR 概要 📝\n本文\n'; } >"$WORK/rv-mixed.exp"
    assert_same_file "SS-9 regression: 混在の本文で、外の行末をそのまま保つ" "$WORK/rv-mixed.exp" "$WORK/rv-mixed.out"

    # R-12 閉じていない囲みがあっても、その後ろの既存のブロックを置き換える（2 つ目を足さない）
    printf 'top\n```\nunclosed\n<!-- series-overview:begin -->\n古い\n<!-- series-overview:end -->\nbody\n' >"$WORK/rv-open.md"
    ss render "$s" --stage A --body-file "$WORK/rv-open.md" >"$WORK/rv-open.out"
    if [[ "$(grep -c 'series-overview:begin' "$WORK/rv-open.out")" == 1 ]] && ! grep -q '古い' "$WORK/rv-open.out"; then
        pass "SS-9 regression: 閉じていない囲みの後ろのブロックも置き換える"
    else
        fail "SS-9 regression: 閉じていない囲みで begin が $(grep -c 'series-overview:begin' "$WORK/rv-open.out") 個"
    fi

    # R-13 ref の行の後の空白だけの行はそのまま残す（目印の外の行）
    printf 'ref A\n  \nbody\n' >"$WORK/rv-refsp.md"
    ss render "$s" --stage A --body-file "$WORK/rv-refsp.md" >"$WORK/rv-refsp.out"
    { printf 'ref A\n  \n'; cat "$WORK/rv-block.txt"; printf '\nbody\n'; } >"$WORK/rv-refsp.exp"
    assert_same_file "SS-9 regression: ref の後の空白だけの行を書き換えない" "$WORK/rv-refsp.exp" "$WORK/rv-refsp.out"

    # R-8 --body-file が無ければ error:（traceback にしない）
    out="$(ss render "$s" --stage A --body-file "$WORK/no-such-body.md" 2>&1)"; rc=$?
    if [[ "$rc" == 1 && "$out" == "error: "* ]]; then pass "SS-9 regression: --body-file が無ければ exit 1 と error:"; else fail "SS-9 regression: --body-file が無い（rc=${rc}）: ${out:0:120}"; fi

    # R-9 書き込みで series.md の権限を変えない
    mk_series "$s" "" "" ""
    chmod 644 "$s"
    ss register "$s" --repo acme/web --branch feat/order-import-notify --pr 5 >/dev/null 2>&1
    local mode; mode="$(ls -l "$s" | cut -c1-10)"
    if [[ "$mode" == "-rw-r--r--" ]]; then pass "SS-9 regression: 書き込みで series.md の権限を保つ"; else fail "SS-9 regression: 権限が ${mode} になった"; fi
}

# ============================================================ SS-10: コードレビューの指摘（regression）

# ## 段 の表に必須でない列「前提」を足す（値は「前提-<段名>」）
add_prereq_column() {  # $1=series.md（その場で書き換える）
    "$PY" - "$1" <<'PYEOF'
import sys
path = sys.argv[1]
lines = open(path, encoding="utf-8").read().split("\n")
for i, line in enumerate(lines):
    if line.startswith("| 段 | リポジトリ |"):
        lines[i] = line + " 前提 |"
    elif line.startswith("|----|-----------|"):
        lines[i] = line + "----|"
    elif line.startswith("| ") and "| acme/" in line:
        lines[i] = line + " 前提-%s |" % line.split("|")[1].strip()
open(path, "w", encoding="utf-8").write("\n".join(lines))
PYEOF
}

run_code_review_regression_tests() {
    local s="$WORK/cr.md" f="$WORK/cr-draft.md" out rc now

    # R-1 register は必須でない列の値を消さない（候補が段 C の 1 行に決まる fixture）
    mk_series "$s" 12 "" ""
    add_prereq_column "$s"
    out="$(ss register "$s" --repo acme/web --branch feat/order-import-notify --pr 5 2>&1)"; rc=$?
    now="$(cat "$s")"
    if [[ "$rc" == 0 && "$out" == "registered:"* && "$now" == *"| feat/order-import-notify | 5 | 前提-C |"* ]]; then
        pass "SS-10 regression: register は段 C を登録する"
    else
        fail "SS-10 regression: register（rc=${rc}）: ${out:0:200}"
    fi
    assert_has "SS-10 regression: register の後も必須でない列が残る（段 A）" "$now" "| 12 | 前提-A |"
    assert_has "SS-10 regression: register の後も必須でない列が残る（段 C）" "$now" "| 5 | 前提-C |"

    # R-2 write は下書きの必須でない列を書く
    mk_series "$s" 12 "" ""
    add_prereq_column "$s"
    mk_series "$f" "" "" ""
    mutate "$f" "$f.2" "直すもの | 解決する事象" "直すもの | 解決する事象（新）"
    add_prereq_column "$f.2"
    # 下書きの段 B だけ値を変える（今の値を残すだけの実装と区別するため）
    mutate "$f.2" "$f.3" "| 前提-B |" "| 前提-B-新 |"
    out="$(ss write "$s" --from "$f.3" 2>&1)"; rc=$?
    now="$(cat "$s")"
    if [[ "$rc" == 0 && "$now" == *"解決する事象（新）"* ]]; then
        pass "SS-10 regression: 必須でない列のある下書きを write できる"
        assert_has "SS-10 regression: write の後も必須でない列が残る（段 A）" "$now" "| 12 | 前提-A |"
        assert_has "SS-10 regression: write は下書きの必須でない列の値を書く（段 B）" "$now" "|  |  | 前提-B-新 |"
    else
        fail "SS-10 regression: 必須でない列のある下書きの write（rc=${rc}）: ${out:0:200}"
    fi

    # R-3 --migrate は囲みの中の --- と ## では止まらない
    mk_series "$s" 12 13 5
    ss render "$s" --stage A >"$WORK/cr-block.txt"
    printf '## 🗺️ 全体像（古い）\n\n```mermaid\n---\nconfig:\n  theme: base\n---\nflowchart LR\n  X --> Y\n```\n\n---\n%s' "$BODY_TAIL" >"$WORK/cr-mig.md"
    ss render "$s" --stage A --body-file "$WORK/cr-mig.md" --migrate >"$WORK/cr-mig.out" 2>&1; rc=$?
    printf '%s\n%s' "$(cat "$WORK/cr-block.txt")" "$BODY_TAIL" >"$WORK/cr-mig.exp"
    if [[ "$rc" == 0 ]] && cmp -s "$WORK/cr-mig.exp" "$WORK/cr-mig.out"; then
        pass "SS-10 regression: --migrate は囲みの中の --- で止まらない"
    else
        fail "SS-10 regression: 囲みの中の ---（rc=${rc}）: $(diff "$WORK/cr-mig.exp" "$WORK/cr-mig.out" | head -6)"
    fi
    printf '## 🗺️ 全体像（古い）\n\n```\n## 囲みの中の見出し\n```\n\n---\n%s' "$BODY_TAIL" >"$WORK/cr-mig2.md"
    ss render "$s" --stage A --body-file "$WORK/cr-mig2.md" --migrate >"$WORK/cr-mig2.out" 2>&1; rc=$?
    if [[ "$rc" == 0 ]] && cmp -s "$WORK/cr-mig.exp" "$WORK/cr-mig2.out"; then
        pass "SS-10 regression: --migrate は囲みの中の ## で止まらない"
    else
        fail "SS-10 regression: 囲みの中の ##（rc=${rc}）: $(head -3 "$WORK/cr-mig2.out")"
    fi

    # R-4 register は空・空白だけのブランチを拒否する（detached HEAD で空になる）
    local br
    for br in "" " "; do
        mk_series "$s" "" "" ""
        cp "$s" "$WORK/cr.before"
        out="$(ss register "$s" --repo acme/web --branch "$br" --pr 9 2>&1)"; rc=$?
        if [[ "$rc" == 1 && "$out" == "error: "*"--branch"* ]] && cmp -s "$WORK/cr.before" "$s"; then
            pass "SS-10 regression: --branch「${br}」は exit 1 で series.md を変えない"
        else
            fail "SS-10 regression: --branch「${br}」（rc=${rc}）: ${out:0:200}"
        fi
    done
}

# ============================================================ SS-11: コードレビューの指摘 2 巡目（regression）

run_code_review2_regression_tests() {
    local s="$WORK/cr2.md" f="$WORK/cr2-draft.md" out rc now
    local row_b_empty="| B | acme/api | S-3 | 段 A に積む | 2 | /wt/api-a |  |  |"

    # R-1 下書きに ## メモ が無くても、今のメモを見出しごと残す（## メモ は人の任意の節）
    mk_series "$s" 12 "" ""
    mk_series "$WORK/cr2-0.md" "" "" ""
    mutate "$WORK/cr2-0.md" "$f" "## メモ"$'\n\n'"手で書いたメモ"$'\n' "" \
        "直すもの | 解決する事象" "直すもの | 解決する事象（新）"
    out="$(ss write "$s" --from "$f" 2>&1)"; rc=$?
    now="$(cat "$s")"
    if [[ "$rc" == 0 && "$now" == *"解決する事象（新）"* ]]; then
        pass "SS-11 regression: ## メモ の無い下書きを write できる"
        assert_has "SS-11 regression: ## メモ の見出しが残る" "$now" $'\n## メモ\n'
        assert_has "SS-11 regression: 今のメモが残る" "$now" "手で書いたメモ"
    else
        fail "SS-11 regression: ## メモ の無い下書きの write（rc=${rc}）: ${out:0:200}"
    fi

    # R-2 リポジトリが変わり PR の無い段は、古いリポジトリのブランチを引き継がない
    mk_series "$WORK/cr2-0.md" "" "" ""
    mutate "$WORK/cr2-0.md" "$s" "$row_b_empty" "| B | acme/api | S-3 | 段 A に積む | 2 | /wt/api-a | feat-b |  |"
    mutate "$WORK/cr2-0.md" "$f" "| B | acme/api |" "| B | acme/web |"
    out="$(ss write "$s" --from "$f" 2>&1)"; rc=$?
    now="$(cat "$s")"
    assert_rc "SS-11 regression: リポジトリが変わり PR の無い段の write は exit 0" 0 "$rc" "$out"
    assert_has "SS-11 regression: 古いブランチを引き継がない" "$now" "| B | acme/web | S-3 | 段 A に積む | 2 | /wt/api-a |  |  |"
    if [[ "$out" == *"reset: 段 B"*"feat-b"* ]]; then pass "SS-11 regression: reset: を出す"; else fail "SS-11 regression: reset: が無い: ${out:0:200}"; fi
    assert_not_has "SS-11 regression: inherited: B を出さない" "$out" "inherited: B"

    # R-3 同じ条件で、下書きのブランチ列に値があれば conflict にせずその値を書く
    mutate "$WORK/cr2-0.md" "$s" "$row_b_empty" "| B | acme/api | S-3 | 段 A に積む | 2 | /wt/api-a | feat-b |  |"
    mutate "$WORK/cr2-0.md" "$f" "$row_b_empty" "| B | acme/web | S-3 | 段 A に積む | 2 | /wt/api-a | feat-web |  |"
    out="$(ss write "$s" --from "$f" 2>&1)"; rc=$?
    now="$(cat "$s")"
    assert_rc "SS-11 regression: 下書きのブランチがあれば exit 0" 0 "$rc" "$out"
    assert_has "SS-11 regression: 下書きのブランチを書く" "$now" "| B | acme/web | S-3 | 段 A に積む | 2 | /wt/api-a | feat-web |  |"

    # R-4 引き継いだ後に同じ PR が 2 つの段に入るなら止める（下書きの check は引き継ぐ前に当たる）
    mk_series "$s" 12 "" ""
    mk_series "$f" "" 12 ""
    cp "$s" "$WORK/cr2.before"
    out="$(ss write "$s" --from "$f" 2>&1)"; rc=$?
    if [[ "$rc" == 3 && "$out" == *"conflict: "*"acme/api#12"* ]] && cmp -s "$WORK/cr2.before" "$s"; then
        pass "SS-11 regression: 引き継いだ後に同じ PR が 2 段なら exit 3 で書かない"
    else
        fail "SS-11 regression: 同じ PR が 2 段（rc=${rc}）: ${out:0:200}"
    fi

    # R-5 register は、セルが見出しより多い行のある series.md を書き直さない
    mk_series "$WORK/cr2-0.md" "" "" ""
    mutate "$WORK/cr2-0.md" "$s" "| 1 | /wt/api-a |  |  |" "| 1 | /wt/api-a |  |  | EXTRA |"
    cp "$s" "$WORK/cr2.before"
    out="$(ss register "$s" --stage A --repo acme/api --branch feat/order-import-recv --pr 12 2>&1)"; rc=$?
    if [[ "$rc" == 1 && "$out" == *"見出しより多い: 段 A"* ]] && cmp -s "$WORK/cr2.before" "$s"; then
        pass "SS-11 regression: セルの多い行があれば register は exit 1 で書かない"
    else
        fail "SS-11 regression: セルの多い行の register（rc=${rc}）: ${out:0:200}"
    fi

    # R-6 セルの中の \| は区切りでない（GFM の表のエスケープ）
    mutate "$WORK/cr2-0.md" "$s" "| S-1・S-2 |" '| S-1 \| S-2 |'
    out="$(ss register "$s" --stage A --repo acme/api --branch feat/order-import-recv --pr 12 2>&1)"; rc=$?
    now="$(cat "$s")"
    if [[ "$rc" == 0 && "$out" == "registered:"* ]]; then
        pass "SS-11 regression: \\| のあるセルの段を register できる"
        assert_has "SS-11 regression: \\| を保ち、列をずらさない" "$now" \
            '| A | acme/api | S-1 \| S-2 | develop | 1 | /wt/api-a | feat/order-import-recv | 12 |'
    else
        fail "SS-11 regression: \\| のあるセルの register（rc=${rc}）: ${out:0:200}"
    fi

    # R-7 write は今の timestamp を保つ（timestamp は status の持ち分）
    local ts_old="timestamp: 2026-01-01T10:00:00+09:00" ts_cur="timestamp: 2026-09-09T09:09:09+09:00"
    mutate "$WORK/cr2-0.md" "$WORK/cr2-cur.md" "$ts_old" "$ts_cur"
    mutate "$WORK/cr2-0.md" "$WORK/cr2-d1.md" "$ts_old"$'\n' "" "直すもの | 解決する事象" "直すもの | 解決する事象（新）"
    mutate "$WORK/cr2-0.md" "$WORK/cr2-d2.md" "直すもの | 解決する事象" "直すもの | 解決する事象（新）"
    local d
    for d in d1 d2; do
        cp "$WORK/cr2-cur.md" "$s"
        out="$(ss write "$s" --from "$WORK/cr2-$d.md" 2>&1)"; rc=$?
        now="$(cat "$s")"
        if [[ "$rc" == 0 && "$now" == *"解決する事象（新）"* && "$now" == *"$ts_cur"* && "$now" != *"$ts_old"* ]]; then
            pass "SS-11 regression: write は今の timestamp を保つ（下書き ${d}）"
        else
            fail "SS-11 regression: timestamp（下書き ${d}、rc=${rc}）: $(grep -n '^timestamp' "$s")"
        fi
    done

    # R-8 info string にバッククォートのある行は囲みを開始しない（CommonMark）
    mk_series "$s" 12 13 5
    printf '```foo``` x\n<!-- series-overview:begin -->\n古い\n<!-- series-overview:end -->\n\n```py\ncode\n```\n' >"$WORK/cr2-tick.md"
    ss render "$s" --stage A --body-file "$WORK/cr2-tick.md" >"$WORK/cr2-tick.out" 2>&1; rc=$?
    if [[ "$rc" == 0 && "$(grep -c 'series-overview:begin' "$WORK/cr2-tick.out")" == 1 ]] && ! grep -q '古い' "$WORK/cr2-tick.out"; then
        pass "SS-11 regression: info string にバッククォートのある行の後ろのブロックを置き換える"
    else
        fail "SS-11 regression: バッククォートの info string（rc=${rc}）で begin が $(grep -c 'series-overview:begin' "$WORK/cr2-tick.out") 個"
    fi

    # R-9 未登録 PR の探索が上限に当たったら、調べ切れていないことを warning で示す
    local n
    for n in 100 99; do
        gh_reset
        mk_series "$s" "" "" ""
        "$PY" -c 'import json,sys; print(json.dumps([{"number": i, "headRefName": "feat/order-import-n%d" % i} for i in range(1, int(sys.argv[1]) + 1)]))' "$n" >"$FAKE_GH_DIR/list/acme__api.json"
        echo '[]' >"$FAKE_GH_DIR/list/acme__web.json"
        out="$(PATH="$FAKE_BIN:$PATH" ss status "$s" 2>&1)"; rc=$?
        if [[ "$n" == 100 ]]; then
            if [[ "$rc" == 0 && "$out" == *"warning: acme/api の feat/order-import- の PR が 100 件以上"* ]]; then
                pass "SS-11 regression: 探索が上限の 100 件に当たったら warning"
            else
                fail "SS-11 regression: 上限の warning（rc=${rc}）: $(printf '%s' "$out" | grep -v '未登録' | head -3)"
            fi
        else
            if [[ "$rc" == 0 && "$out" == *"未登録の PR: acme/api#99"* && "$out" != *"件以上"* ]]; then
                pass "SS-11 regression: 99 件では上限の warning を出さない"
            else
                fail "SS-11 regression: 99 件（rc=${rc}）: $(printf '%s' "$out" | grep -v '未登録' | head -3)"
            fi
        fi
    done

    # R-10 閉じていない囲みがあっても、series.md の節を見失わない（outside_fences と同じ規則）
    mk_series "$WORK/cr2-0.md" 12 "" ""
    mutate "$WORK/cr2-0.md" "$s" $'\n## 進捗\n' $'\n```\n\n## 進捗\n'
    out="$(ss check "$s" 2>&1)"; rc=$?
    assert_not_has "SS-11 regression: 閉じていない囲みの後ろの ## 進捗 を見失わない" "$out" "## 進捗 の節が無い"
    # 節は見失わないが、壊れた series.md なので黙って通さない
    if [[ "$rc" == 1 && "$out" == "error: 閉じていないコードの囲みがある" ]]; then
        pass "SS-11 regression: 閉じていない囲みは check の error（その 1 件だけ）"
    else
        fail "SS-11 regression: 閉じていない囲みの check（rc=${rc}）: ${out:0:200}"
    fi
}

# ============================================================ 実行

# python3 と /usr/bin/python3 が別物なら両方で全件を回す（3.9 で動くことの検証）
PYS=(python3)
if [[ -x /usr/bin/python3 ]] && \
    [[ "$(/usr/bin/python3 -c 'import sys; print(sys.version)')" != "$(python3 -c 'import sys; print(sys.version)')" ]]; then
    PYS+=(/usr/bin/python3)
fi

if [[ ! -f "$SYNC" ]]; then
    echo "test-series-sync.sh: 検査対象が見つからない: $SYNC" >&2
fi

run_no=0
for PY in "${PYS[@]}"; do
    run_no=$((run_no + 1))
    WORK="$BASE/run-$run_no"
    mkdir -p "$WORK"
    LABEL="[$("$PY" -c 'import sys; print("py%d.%d" % sys.version_info[:2])')] "
    echo "== ${PY}（$("$PY" --version 2>&1)）=="
    run_check_tests
    run_render_block_tests
    run_render_body_tests
    run_register_tests
    run_write_tests
    run_status_tests
    run_plan_tests
    run_apply_tests
    run_review_regression_tests
    run_code_review_regression_tests
    run_code_review2_regression_tests
done

echo
echo "${pass_count} passed / ${fail_count} failed（python: ${PYS[*]}）"
[[ "$fail_count" -eq 0 ]] || exit 1
