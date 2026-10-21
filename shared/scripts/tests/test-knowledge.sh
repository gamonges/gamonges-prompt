#!/usr/bin/env bash
# tmp/ の md の frontmatter の CLI（shared/scripts/knowledge.py）の挙動テスト。
#
# CLI は hook（hook-lint-skill-frontmatter.sh）から呼ばれる判定の本体で、壊れると
# 「tmp/ の md の書き込みが黙って通る」か「既存の文書への追記が止まり続ける」かのどちらかになる。
# hook 側の配線は test-guardrails.sh の TM 節が見る。ここでは規則そのものを見る。
#
# CLI は /usr/bin/python3（3.9）でも動かす前提なので、python3 と /usr/bin/python3 が
# 別物なら両方で全件を回す。HOME は差し替えない（mise の shim が壊れるため）。
#
# 起動: bash shared/scripts/tests/test-knowledge.sh

# set -e は使わない。1 件目の失敗で残りが走らなくなると、Red で全件の失敗を確かめられない
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
KN="$REPO_ROOT/shared/scripts/knowledge.py"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass_count=0
fail_count=0
LABEL=""

pass() { echo -e "${GREEN}[PASS]${NC} ${LABEL}$1"; pass_count=$((pass_count + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} ${LABEL}$1"; fail_count=$((fail_count + 1)); }

# python ごとの回で WORK を分ける（前の回の写しや index.md が残ると、-2 や上書きの判定が狂う）
BASE="$(mktemp -d)"
WORK="$BASE"
cleanup() { rm -rf "$BASE"; }
trap cleanup EXIT

# ============================================================ 共通の道具

assert_rc() {  # $1=名前 $2=期待 $3=実際 $4=出力（失敗時に見せる）
    if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1（rc=$3、期待 $2）: ${4:0:400}"; fi
}

assert_has() {  # $1=名前 $2=出力 $3=含むべき文字列
    if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1（「$3」が無い）: ${2:0:400}"; fi
}

# 内部エラー（exit 2）は CLI 自身の error: 行も見る。python がファイルを開けないときも exit 2 なので、
# 終了コードだけでは CLI が無い状態でも通ってしまう
assert_error() {  # $1=名前 $2=error: 行に含むべき語（省略可。argparse 自身の error: 行との偶然の一致を避ける）
    if [[ "$RC" == 2 && "$OUT" == *"error: "*"${2-}"* ]]; then pass "$1"; else fail "$1（rc=${RC}、期待 2 と error: 行 ${2-}）: ${OUT:0:400}"; fi
}

assert_not_has() {  # $1=名前 $2=出力 $3=含まないはずの文字列
    if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1（「$3」がある）: ${2:0:400}"; fi
}

kn() { "$PY" "$KN" "$@"; }

# fixture の git は利用者の設定に依存させない
git_init() {
    mkdir -p "$1"
    git -C "$1" init -q
}

FM_FULL=$'---\ntype: Implementation Plan\ntitle: 題材\ndescription: 要約の 1 文\nstatus: stable\n---\n# 実装計画: 題材\n'

# check を呼び、出力と終了コードを OUT・RC に入れる。$1=本文（stdin）、以降 check の引数
ck() {
    local content="$1"; shift
    OUT="$(printf '%s' "$content" | kn check "$@" 2>&1)"; RC=$?
}

# ============================================================ CK: check

run_check_tests() {
    local R="$WORK/repo" old
    git_init "$R"
    mkdir -p "$R/tmp" "$R/docs"

    # --- CK-scope: 対象の判定（C-1）。frontmatter の無い本文を write で渡し、1 なら対象・0 なら対象外 ---
    local no_fm=$'# 見出し\n本文\n'
    ck "$no_fm" --path "$R/tmp/x.md" --op write
    assert_rc "CK-scope repo 直下の tmp/x.md は対象" 1 "$RC" "$OUT"
    ck "$no_fm" --path "$R/tmp/sub/x.md" --op write
    assert_rc "CK-scope tmp/ の下の階層も対象" 1 "$RC" "$OUT"
    ck "$no_fm" --path "$R/tmp/X.MD" --op write
    assert_rc "CK-scope 拡張子の大文字小文字を区別しない" 1 "$RC" "$OUT"
    local p
    for p in "$WORK/scratch/tmp/x.md" "/private/tmp/claude-501/s/x.md" "/tmp/x.md" \
        "$R/tmp/_runs/a.md" "$R/tmp/_runs/series-sync/1/a.md" "$R/tmp/_assets/a.md" \
        "$R/tmp/index.md" "$R/tmp/sub/log.md" "$R/tmp/s/SKILL.md" "$R/tmp/s/skill.md" \
        "$R/tmp/x.txt" "$R/packages/a/tmp/x.md" "$R/docs/x.md" "$R/tmp/_RUNS/a.md"; do
        ck "$no_fm" --path "$p" --op write
        assert_rc "CK-scope 対象外: ${p#"$WORK"/}" 0 "$RC" "$OUT"
    done
    # ディレクトリ名も大文字小文字を区別しない（拡張子と同じく APFS）。symlink を経由した書き込みは実体で見る
    # （まだ無いサブディレクトリでも祖先の symlink を解決する）。tmp 自体が repo の外への symlink でも、字面で当たれば対象
    ln -s tmp "$R/t2"
    local R2="$WORK/repo-outlink"
    git_init "$R2"
    mkdir -p "$WORK/outside-tmp"
    ln -s "$WORK/outside-tmp" "$R2/tmp"
    for p in "$R/TMP/new.md" "$R/Tmp/x.md" "$R/t2/new.md" "$R/t2/new-dir/x.md" "$R2/tmp/x.md"; do
        ck "$no_fm" --path "$p" --op write
        assert_rc "CK-scope 対象: ${p#"$WORK"/}" 1 "$RC" "$OUT"
    done
    rm -f "$R/t2"

    # --- CK-write: 必須キーと値（C-2） ---
    local T="$R/tmp/plan.md"
    ck "$FM_FULL" --path "$T" --op write
    assert_rc "CK-write 4 キーが揃えば 0" 0 "$RC" "$OUT"
    ck $'---\ntype: X\ntitle: t\ndescription: d\nstatus: draft\nauthor: me\ntags: [a, b]\n---\n' --path "$T" --op write
    assert_rc "CK-write 未知のキー・登録表に無い type でも 0（OKF §4.1）" 0 "$RC" "$OUT"
    local key body
    for key in type title description status; do
        body="$(printf '%s' "$FM_FULL" | grep -v "^${key}:")"
        ck "$body" --path "$T" --op write
        assert_rc "CK-write ${key} の欠落は 1" 1 "$RC" "$OUT"
        assert_has "CK-write ${key} の欠落を理由に出す" "$OUT" "missing:${key}"
    done
    ck "${FM_FULL/title: 題材/title:}" --path "$T" --op write
    assert_rc "CK-write 空の値は 1" 1 "$RC" "$OUT"
    ck "${FM_FULL/title: 題材/title: \"\"}" --path "$T" --op write
    assert_rc "CK-write 引用符だけの空の値は 1" 1 "$RC" "$OUT"
    ck "${FM_FULL/title: 題材/title: \"題材: 副題\"}" --path "$T" --op write
    assert_rc "CK-write 引用符で囲んだ値（中に :）は 0" 0 "$RC" "$OUT"
    ck "${FM_FULL/status: stable/status: foo}" --path "$T" --op write
    assert_rc "CK-write status: foo は 1" 1 "$RC" "$OUT"
    assert_has "CK-write status の不正を理由に出す" "$OUT" "invalid:status"
    ck "${FM_FULL/status: stable/status: deprecated}" --path "$T" --op write
    assert_rc "CK-write deprecated で superseded_by なしは 1" 1 "$RC" "$OUT"
    assert_has "CK-write superseded_by の欠落を理由に出す" "$OUT" "missing:superseded_by"
    ck "${FM_FULL/status: stable/status: deprecated
superseded_by: tmp/plan.md}" --path "$T" --op write
    assert_rc "CK-write deprecated で superseded_by ありは 0" 0 "$RC" "$OUT"

    # --- CK-encoding: 出力先が UTF-8 でなくても、違反は rc 1 と理由で返す（traceback の rc 1 は違反ありと区別できない） ---
    OUT="$(printf '%s' "$no_fm" | PYTHONIOENCODING=ascii kn check --path "$T" --op write 2>&1)"; RC=$?
    assert_rc "CK-encoding 出力先が ascii でも違反は 1" 1 "$RC" "$OUT"
    assert_has "CK-encoding 出力先が ascii でも理由を出す" "$OUT" "type:"
    if [[ "$OUT" != *Traceback* ]]; then pass "CK-encoding traceback を出さない"; else fail "CK-encoding traceback: $OUT"; fi

    # --- CK-syntax: 平坦な key: value 以外は違反（C-7）。黙って別のキーに化けさせない ---
    ck "${FM_FULL/description: 要約の 1 文/description: |
  1 行目
  2 行目}" --path "$T" --op write
    assert_rc "CK-syntax 複数行の値（|）は 1" 1 "$RC" "$OUT"
    assert_has "CK-syntax 未対応の書式を理由に出す" "$OUT" "unsupported-syntax"
    ck "${FM_FULL/description: 要約の 1 文/description: >-}" --path "$T" --op write
    assert_rc "CK-syntax 折り返しの値（>-）は 1" 1 "$RC" "$OUT"
    # ブロックスカラーは見出しだけの値。> や | で始まる普通の文は値として読む
    ck "${FM_FULL/description: 要約の 1 文/description: > 50% 速くなった}" --path "$T" --op write
    assert_rc "CK-syntax > で始まる普通の文は 0" 0 "$RC" "$OUT"
    ck "${FM_FULL/description: 要約の 1 文/description: | の使い方}" --path "$T" --op write
    assert_rc "CK-syntax | で始まる普通の文は 0" 0 "$RC" "$OUT"
    local hdr
    for hdr in '|2' '>+ # c' '|-' '>'; do
        ck "${FM_FULL/description: 要約の 1 文/description: $hdr}" --path "$T" --op write
        assert_rc "CK-syntax ブロックスカラーの見出し（${hdr}）は 1" 1 "$RC" "$OUT"
    done
    assert_has "CK-syntax 未対応の書式には引用の案内を出す" "$OUT" "引用"
    ck "${FM_FULL/status: stable/status: stable
generated:
  at: 2026-10-21}" --path "$T" --op write
    assert_rc "CK-syntax ネストした値（字下げの行）は 1" 1 "$RC" "$OUT"
    assert_has "CK-syntax ネストも未対応の書式" "$OUT" "unsupported-syntax"
    ck "${FM_FULL/status: stable/status: stable
  title: 別の題材}" --path "$T" --op write
    assert_rc "CK-syntax 字下げした title 行をキーとして読まない" 1 "$RC" "$OUT"
    ck "${FM_FULL/status: stable/status: stable
# コメント

}" --path "$T" --op write
    assert_rc "CK-syntax コメント行と空行は許す" 0 "$RC" "$OUT"

    # --- CK-range: frontmatter は先頭行の --- から次の --- まで（C-6） ---
    ck $'# 調査\n本文\n\n---\n\ntype: X\ntitle: t\ndescription: d\nstatus: stable\n---\n' --path "$T" --op write
    assert_rc "CK-range 途中の --- だけなら frontmatter なし（1）" 1 "$RC" "$OUT"
    assert_has "CK-range frontmatter なしの理由" "$OUT" "frontmatter がありません"
    ck $'---\ntype: X\ntitle: t\ndescription: d\nstatus: stable\n' --path "$T" --op write
    assert_rc "CK-range 閉じの --- が無ければ frontmatter なし（1）" 1 "$RC" "$OUT"
    assert_has "CK-range 閉じなしも frontmatter なしの理由" "$OUT" "frontmatter がありません"
    ck "${FM_FULL}"$'\n---\nstatus: foo\n---\n' --path "$T" --op write
    assert_rc "CK-range 本文の 2 つ目の --- ブロックは読まない" 0 "$RC" "$OUT"

    # --- CK-bom: 先頭の BOM を外してから読む。stdin（write）と --old-file（edit の基準）の両方 ---
    local bom=$'\xef\xbb\xbf'
    ck "${bom}${FM_FULL}" --path "$T" --op write
    assert_rc "CK-bom BOM 付きで 4 キーがそろった write は 0" 0 "$RC" "$OUT"
    printf '%s' "${bom}${FM_FULL}" >"$WORK/bom-old.md"
    ck "$(printf '%s' "$FM_FULL" | grep -v '^type:')" --path "$T" --op edit --old-file "$WORK/bom-old.md"
    assert_rc "CK-bom BOM 付きの既存文書から type を消す edit は 1（grandfather しない）" 1 "$RC" "$OUT"

    # --- CK-template: 違反の出力に、パスから引いた種類の雛形（C-8） ---
    ck "$no_fm" --path "$R/tmp/plan.md" --op write
    assert_has "CK-template plan.md → Implementation Plan" "$OUT" "type: Implementation Plan"
    assert_has "CK-template 雛形に status" "$OUT" "status: stable"
    ck "$no_fm" --path "$R/tmp/plan-review.md" --op write
    assert_has "CK-template plan-review.md → Plan Review（glob より具体名が先）" "$OUT" "type: Plan Review"
    ck "$no_fm" --path "$R/tmp/fix-plan.md" --op write
    assert_has "CK-template fix-plan.md → Fix Plan" "$OUT" "type: Fix Plan"
    ck "$no_fm" --path "$R/tmp/plan-foo.md" --op write
    assert_has "CK-template plan-foo.md → Implementation Plan" "$OUT" "type: Implementation Plan"
    ck "$no_fm" --path "$R/tmp/review/security-review.md" --op write
    assert_has "CK-template review/*.md → Review Report" "$OUT" "type: Review Report"
    ck "$no_fm" --path "$R/tmp/plan-x/foo.md" --op write
    assert_has "CK-template glob は / を跨がない（plan-x/foo.md は不明）" "$OUT" "type: <種類>"
    # 写し（.archived-）は元の名前で種類を引き、旧版の雛形（deprecated・後継）を出す。手で写しを作る経路の deny から直せるように
    ck "$no_fm" --path "$R/tmp/plan.archived-20261021-1030-x.md" --op write
    assert_has "CK-template 写しは元の名前で種類を引く" "$OUT" "type: Implementation Plan"
    assert_has "CK-template 写しの雛形は deprecated" "$OUT" "status: deprecated"
    assert_has "CK-template 写しの雛形の後継は元のパス" "$OUT" "superseded_by: tmp/plan.md"
    assert_has "CK-template 写しの雛形に理由の欄" "$OUT" "archived_reason: <理由>"
    ck "$no_fm" --path "$R/tmp/plan-review.archived-20261021-1030-x.md" --op write
    assert_has "CK-template 写しでも具体名が glob より先（plan-review）" "$OUT" "type: Plan Review"
    ck "$no_fm" --path "$R/tmp/review.archived-20261021-1030-x/unified.md" --op write
    assert_has "CK-template ディレクトリの写しの中は元のディレクトリで種類を引く" "$OUT" "type: Review Report"
    assert_has "CK-template ディレクトリの写しの後継は元のディレクトリ" "$OUT" "superseded_by: tmp/review/"
    ck "$no_fm" --path "$R/tmp/zzz.md" --op write
    assert_has "CK-template 登録表に無い名前は <種類>" "$OUT" "type: <種類>"

    # --- CK-edit: 書く前の中身と違反の集合を比べる（C-3） ---
    old="$WORK/old.md"
    printf '%s' "$no_fm" >"$old"
    ck $'# 見出し\n本文を足した\n' --path "$T" --op edit --old-file "$old"
    assert_rc "CK-edit 書く前が frontmatter なしなら 0（今ある文書）" 0 "$RC" "$OUT"
    ck "$FM_FULL" --path "$T" --op edit --old-file "$old"
    assert_rc "CK-edit frontmatter なしの文書に正しい frontmatter を付ける edit は 0" 0 "$RC" "$OUT"
    # 違反の集合の差だけでは no-frontmatter → missing:* が「増えた」に見える。免除はこのケースで効く
    ck $'---\ntype: Implementation Plan\n---\n# 見出し\n' --path "$T" --op edit --old-file "$old"
    assert_rc "CK-edit frontmatter なしの文書に不完全な frontmatter を付ける edit も 0" 0 "$RC" "$OUT"
    # 免除するのはキーの不足だけ。付けた値の誤りを通すと、以後の Edit がその誤りを基準に grandfather される
    ck $'---\ntype: X\ntitle: t\ndescription: d\nstatus: foo\n---\n# 見出し\n' --path "$T" --op edit --old-file "$old"
    assert_rc "CK-edit frontmatter なしの文書に status: foo を付ける edit は 1" 1 "$RC" "$OUT"
    assert_has "CK-edit 付けた値の誤りを理由に出す" "$OUT" "invalid:status"
    ck $'---\ntype: X\ntitle: t\ndescription: d\nstatus: deprecated\n---\n# 見出し\n' --path "$T" --op edit --old-file "$old"
    assert_rc "CK-edit frontmatter なしの文書に後継の無い deprecated を付ける edit は 1" 1 "$RC" "$OUT"
    assert_has "CK-edit 後継の欠落を理由に出す" "$OUT" "missing:superseded_by"
    ck $'---\ntype: X\ntitle: |\n  t\n---\n# 見出し\n' --path "$T" --op edit --old-file "$old"
    assert_rc "CK-edit frontmatter なしの文書に複数行の値を付ける edit は 1" 1 "$RC" "$OUT"
    assert_has "CK-edit 未対応の書式を理由に出す（付ける edit）" "$OUT" "unsupported-syntax"
    printf '%s' "$FM_FULL" >"$old"
    ck "${FM_FULL}"$'本文を足した\n' --path "$T" --op edit --old-file "$old"
    assert_rc "CK-edit 揃った frontmatter のまま本文を変える edit は 0" 0 "$RC" "$OUT"
    ck $'# 実装計画: 題材\n' --path "$T" --op edit --old-file "$old"
    assert_rc "CK-edit frontmatter を消す edit は 1" 1 "$RC" "$OUT"
    assert_has "CK-edit frontmatter を消す edit の理由" "$OUT" "no-frontmatter"
    ck "$(printf '%s' "$FM_FULL" | grep -v '^type:')" --path "$T" --op edit --old-file "$old"
    assert_rc "CK-edit 必須キーを 1 つ消す edit は 1" 1 "$RC" "$OUT"
    ck "${FM_FULL/status: stable/status: foo}" --path "$T" --op edit --old-file "$old"
    assert_rc "CK-edit status を foo にする edit は 1" 1 "$RC" "$OUT"

    # --- CK-edit-legacy: install 前の不完全な frontmatter（C-3） ---
    local ctx=$'---\nmode: concept\ntitle: 題材\nbase_commit: abc123\n---\n\n# 背景\n'
    printf '%s' "$ctx" >"$old"
    ck "${ctx}"$'\n## 追記した節\n本文\n' --path "$R/tmp/context.md" --op edit --old-file "$old"
    assert_rc "CK-edit-legacy brief の context.md に節を足す edit は 0" 0 "$RC" "$OUT"
    local grill=$'---\ntype: Grill Session\ntitle: 題材\ndescription: 壁打ち\ntimestamp: 2026-10-20T10:00:00+09:00\n---\n\n# 壁打ち\n'
    printf '%s' "$grill" >"$old"
    ck "${grill/2026-10-20T10:00:00/2026-10-21T11:00:00}"$'決定を足した\n' --path "$R/tmp/grill.md" --op edit --old-file "$old"
    assert_rc "CK-edit-legacy status の無い grill.md の本文と timestamp を変える edit は 0" 0 "$RC" "$OUT"
    ck "$(printf '%s' "$grill" | grep -v '^title:')" --path "$R/tmp/grill.md" --op edit --old-file "$old"
    assert_rc "CK-edit-legacy 同じ grill.md の title を消す edit は 1" 1 "$RC" "$OUT"
    assert_has "CK-edit-legacy 増えた違反だけを理由に出す" "$OUT" "missing:title"
    assert_not_has "CK-edit-legacy 書く前から在った違反は理由に出さない" "$OUT" "missing:status"

    # --- CK-edit-move: 移動の元が対象外なら write として検査（C-4） ---
    printf '%s' "$no_fm" >"$old"
    ck "$no_fm" --path "$R/tmp/new.md" --op edit --old-file "$old" --old-path "$R/docs/x.md"
    assert_rc "CK-edit-move 対象外（docs/x.md）から tmp/ への移動は write として 1" 1 "$RC" "$OUT"
    ck "$no_fm" --path "$R/tmp/b.md" --op edit --old-file "$old" --old-path "$R/tmp/a.md"
    assert_rc "CK-edit-move tmp/ の中の移動は今ある文書のまま 0" 0 "$RC" "$OUT"
    ck "$no_fm" --path "$R/tmp/b.md" --op edit --old-file "$old" --old-path "$R/tmp/_runs/a.md"
    assert_rc "CK-edit-move 除外（_runs/）からの移動も write として 1" 1 "$RC" "$OUT"

    # --- CK-args: 相対パス・引数の不足は内部エラー（C-5） ---
    ck "$no_fm" --path "tmp/x.md" --op write
    assert_error "CK-args 相対の --path は 2" "--path"
    ck "$no_fm" --path "$T" --op edit --old-file "$old" --old-path "tmp/a.md"
    assert_error "CK-args 相対の --old-path は 2" "--old-path"
    ck "$no_fm" --path "$T" --op edit
    assert_error "CK-args edit で --old-file が無ければ 2" "--old-file"
    ck "$no_fm" --path "$T" --op edit --old-file "$WORK/no-such-file"
    assert_error "CK-args 読めない --old-file は 2" "no-such-file"
    ck "$no_fm" --path "$T" --op rename
    assert_error "CK-args 未知の --op は 2" "rename"

    # --- CK-utf8: 入力の文字コード。3.9 の偽の UTF-8 エラー（C-9）はソースの長い行で起きるので、
    # 検出点はデータではなく、全件を /usr/bin/python3 でも回すこと（下の「実行」） ---
    ck $'---\ntype: X\ntitle: \xff\xfe\ndescription: d\nstatus: stable\n---\n' --path "$T" --op write
    assert_rc "CK-utf8 不正な UTF-8 でも落ちずに判定する" 0 "$RC" "$OUT"
}

# ============================================================ LI: lint・index

# 実際の tmp/ の形の fixture。$1=repo（git init 済み）。違反を含めるかを $2（1/0）で選ぶ
mk_tmp() {
    local t="$1/tmp"
    mkdir -p "$t/review" "$t/review.archived-20261021-1030-r1" "$t/_runs/series-sync/1" "$t/_assets/screenshots" "$t/sub"
    printf '%s' "$FM_FULL" >"$t/plan.md"
    printf -- '---\ntype: Implementation Plan\ntitle: 前の題材\ndescription: 前の版\nstatus: deprecated\nsuperseded_by: tmp/plan.md\n---\n' \
        >"$t/plan.archived-20261021-1030-r1.md"
    printf -- '---\ntype: Research\ntitle: 調査中\ndescription: 書きかけ\nstatus: draft\n---\n' >"$t/draft.md"
    printf '# 調査\n\n---\n\n追記\n' >"$t/research.md"
    printf -- '---\nmode: concept\ntitle: 題材\nbase_commit: abc\n---\n' >"$t/context.md"
    printf -- '---\ntype: Grill Session\ntitle: 壁打ち\ndescription: 決定の記録\n---\n' >"$t/grill.md"
    printf -- '---\ntype: Review Report\ntitle: 統合レビュー\ndescription: 指摘のまとめ\nstatus: stable\n---\n' >"$t/review/unified.md"
    printf -- '---\ntype: Review Report\ntitle: 前のレビュー\ndescription: 前回\nstatus: deprecated\nsuperseded_by: tmp/review/\n---\n' \
        >"$t/review.archived-20261021-1030-r1/security-review.md"
    printf '# log\n' >"$t/_runs/series-sync/1/a.md"
    printf '# asset\n' >"$t/_assets/screenshots/s.md"
    printf 'png' >"$t/_assets/screenshots/s.png"
    printf '<html>' >"$t/plan.html"
    printf '# log\n' >"$t/sub/log.md"
    if [[ "${2:-1}" == 1 ]]; then
        printf -- '---\ntype: X\ntitle: t\ndescription: d\nstatus: foo\n---\n' >"$t/bad.md"
        printf -- '---\ntype: X\ntitle: t\ndescription: d\nstatus: deprecated\nsuperseded_by: tmp/gone.md\n---\n' >"$t/dangling.md"
    fi
}

run_lint_index_tests() {
    local R="$WORK/li" C="$WORK/li-clean" out rc

    # --- LI-lint: 4 区分と終了コード（C-10） ---
    git_init "$R"; mk_tmp "$R" 1
    out="$(kn lint --tmp "$R/tmp" 2>&1)"; rc=$?
    assert_rc "LI-lint 違反があれば 1" 1 "$rc" "$out"
    assert_has "LI-lint status: foo は違反" "$out" "bad.md: invalid:status"
    assert_has "LI-lint 後継のファイルが無ければ違反" "$out" "dangling.md: invalid:superseded_by"
    assert_has "LI-lint 旧形式の context.md はキーの不足" "$out" "context.md: missing:description, missing:status, missing:type"
    assert_has "LI-lint status の無い grill.md はキーの不足" "$out" "grill.md: missing:status"
    assert_has "LI-lint frontmatter なしの節" "$out" $'frontmatter なし: 1\n  research.md'
    assert_has "LI-lint 違反の件数" "$out" "違反: 2"
    assert_has "LI-lint キーの不足の件数" "$out" "キーの不足: 2"
    assert_has "LI-lint 正常の件数（後継がディレクトリで在る写しを含む）" "$out" "正常: 5"
    assert_not_has "LI-lint _runs/ の md は載らない" "$out" "series-sync"
    assert_not_has "LI-lint _assets/ の md は載らない" "$out" "screenshots"
    assert_not_has "LI-lint log.md は載らない" "$out" "log.md"

    git_init "$C"; mk_tmp "$C" 0
    out="$(kn lint --tmp "$C/tmp" 2>&1)"; rc=$?
    assert_rc "LI-lint キーの不足と frontmatter なしだけなら 0" 0 "$rc" "$out"

    # --- LI-lint（再レビューの後）: 写しの後継は tmp/review/ なので、中身が入れ替わっても満たす ---
    rm -f "$C/tmp/review/"*
    printf -- '---\ntype: Review Report\ntitle: 新しいレビュー\ndescription: 別の構成\nstatus: stable\n---\n' >"$C/tmp/review/perf-review.md"
    out="$(kn lint --tmp "$C/tmp" 2>&1)"; rc=$?
    assert_rc "LI-lint 前回の security-review.md が無くても写しは違反にしない" 0 "$rc" "$out"
    rm -rf "$C/tmp/review"
    out="$(kn lint --tmp "$C/tmp" 2>&1)"; rc=$?
    assert_rc "LI-lint 後継のディレクトリごと無ければ違反" 1 "$rc" "$out"
    mkdir -p "$C/tmp/review"

    # --- LI-default: --tmp の省略は git の toplevel の下の tmp/（C-12） ---
    out="$(cd "$R/tmp/review" && kn lint 2>&1)"; rc=$?
    assert_rc "LI-default サブディレクトリから回しても repo の tmp/ を読む" 1 "$rc" "$out"
    assert_has "LI-default repo の tmp/ の違反が出る" "$out" "bad.md: invalid:status"
    mkdir -p "$WORK/norepo"
    OUT="$(cd "$WORK/norepo" && kn lint 2>&1)"; RC=$?
    assert_error "LI-default repo の外では 2" "git"
    OUT="$(kn lint --tmp "$WORK/no-such-tmp" 2>&1)"; RC=$?
    assert_error "LI-default 無い --tmp は 2" "no-such-tmp"

    # 読めない文書は lint の「違反あり」（1）と取り違えないよう内部エラーの 2
    mkdir -p "$WORK/li-unread/tmp"; git_init "$WORK/li-unread"
    printf 'x\n' >"$WORK/li-unread/tmp/locked.md"; chmod 000 "$WORK/li-unread/tmp/locked.md"
    OUT="$(kn lint --tmp "$WORK/li-unread/tmp" 2>&1)"; RC=$?
    assert_error "LI-lint 読めない文書は 2" "locked.md"
    chmod 644 "$WORK/li-unread/tmp/locked.md"

    # --- LI-index: 目録（C-13・C-14） ---
    out="$(kn index --tmp "$R/tmp" 2>&1)"; rc=$?
    assert_rc "LI-index 違反があっても目録は書いて 0" 0 "$rc" "$out"
    local idx="$R/tmp/index.md" body
    body="$(cat "$idx" 2>/dev/null)"
    assert_has "LI-index 先頭行は自動生成の印" "$(head -1 "$idx" 2>/dev/null)" "自動生成。手で編集しない。"
    assert_has "LI-index 種類ごとの節" "$body" "## Implementation Plan"
    assert_has "LI-index 現行に title と description" "$body" $'### 現行\n\n* [題材](<plan.md>) - 要約の 1 文'
    assert_has "LI-index 旧版を分ける" "$body" $'### 旧版（deprecated）\n\n* [前の題材](<plan.archived-20261021-1030-r1.md>) - 前の版'
    assert_has "LI-index draft は現行に印つきで載る" "$body" "* [調査中](<draft.md>) - 書きかけ（draft）"
    assert_has "LI-index 下の階層の写しも載る" "$body" "(<review.archived-20261021-1030-r1/security-review.md>)"
    assert_has "LI-index キーの不足の節" "$body" "* [壁打ち](<grill.md>) - missing:status"
    assert_has "LI-index frontmatter なしの節" "$body" $'## frontmatter なし\n\n* [research.md](<research.md>)'
    assert_has "LI-index 違反の節" "$body" "* [t](<bad.md>) - invalid:status"
    local n
    for n in "series-sync" "screenshots" "plan.html" "s.png" "log.md" "(index.md)" "(<index.md>)"; do
        assert_not_has "LI-index 載らない: $n" "$body" "$n"
    done
    # リンク先は <…> で囲む（空白・括弧を含む名前で壊れない）。< と > は %3C・%3E にする
    local R3="$WORK/li-link"
    git_init "$R3"; mkdir -p "$R3/tmp"
    printf -- '---\ntype: Research\ntitle: 空白\ndescription: d\nstatus: stable\n---\n' >"$R3/tmp/a b (1).md"
    printf -- '---\ntype: Research\ntitle: 山括弧\ndescription: d\nstatus: stable\n---\n' >"$R3/tmp/x<y>.md"
    out="$(kn index --tmp "$R3/tmp" --stdout 2>&1)"
    assert_has "LI-index 空白と括弧の名前はリンク先を <…> で囲む" "$out" "* [空白](<a b (1).md>)"
    assert_has "LI-index 名前の < と > は %3C・%3E" "$out" "* [山括弧](<x%3Cy%3E.md>)"
    local order
    order="$(grep -n '^## ' "$idx" | cut -d: -f2- | tr '\n' '|')"
    if [[ "$order" == *"## キーの不足|## frontmatter なし|## 違反|" ]]; then
        pass "LI-index 末尾の節の並び（キーの不足 → frontmatter なし → 違反）"
    else
        fail "LI-index 末尾の節の並び: $order"
    fi
    cp "$idx" "$WORK/idx.1"
    kn index --tmp "$R/tmp" >/dev/null 2>&1
    if cmp -s "$WORK/idx.1" "$idx"; then pass "LI-index 2 回回して同じ中身"; else fail "LI-index 冪等でない: $(diff "$WORK/idx.1" "$idx" | head -5)"; fi

    # --stdout は書かずに同じ目録を出す（/status は読み取り専用なので、これを使う）
    out="$(kn index --tmp "$R/tmp" --stdout 2>&1)"; rc=$?
    assert_rc "LI-index --stdout は 0" 0 "$rc" "$out"
    if [[ "$out"$'\n' == "$(cat "$idx")"$'\n' ]]; then pass "LI-index --stdout は書く目録と同じ中身"; else fail "LI-index --stdout の中身: ${out:0:200}"; fi
    rm -f "$idx"
    kn index --tmp "$R/tmp" --stdout >/dev/null 2>&1
    if [[ ! -e "$idx" ]]; then pass "LI-index --stdout は index.md を書かない"; else fail "LI-index --stdout が index.md を書いた"; fi
    kn index --tmp "$R/tmp" >/dev/null 2>&1

    # 自分の生成物でない index.md は上書きしない
    printf '# 手で書いた目録\n' >"$C/tmp/index.md"
    OUT="$(kn index --tmp "$C/tmp" 2>&1)"; RC=$?
    assert_error "LI-index 他人の index.md があれば 2" "index.md"
    assert_has "LI-index 他人の index.md は変えない" "$(cat "$C/tmp/index.md")" "# 手で書いた目録"
}

# ============================================================ SN: snapshot

# 続けて 2 回 snapshot し、2 回目が 1 回目の名前に -2 を付けたものになるか。分の境目を跨いだ
# （2 回の時刻が違う）ときだけ、最大 3 回までやり直す。跨がなかったのに -2 でなければ失敗にする
sn_touch() {  # $1=ファイルかディレクトリ, $2=印。ファイルには行を足し、ディレクトリは中の md すべてに足す
    if [[ -d "$1" ]]; then find "$1" -name '*.md' -exec sh -c 'printf "%s\n" "$1" >>"$2"' _ "$2" {} \;; else printf '%s\n' "$2" >>"$1"; fi
}
sn_grep() {  # $1=写し（ファイルかディレクトリ）, $2=印 → 当たったパス
    grep -rl -- "$2" "$1" 2>/dev/null
}
sn_dup() {  # $1=ラベル, $2=tmp/ からのパス（ディレクトリは末尾の / を付けない）。cwd は $S
    local first second n one
    for n in 1 2 3; do
        # 試行ごとに理由を変える（前の試行の写しと名前がぶつかると -3 になり、期待の -2 と比べられない）
        first="$(cd "$S" && kn snapshot "$2" --reason "dup$n" 2>/dev/null)"
        # 2 回の間で元を変える。2 回目が 1 回目の写しに書けば、1 回目の写しにこの印が入る
        sn_touch "$S/$2" "second-$n"
        second="$(cd "$S" && kn snapshot "$2" --reason "dup$n" 2>/dev/null)"
        if [[ -n "$first" && ( "$second" == "${first%.md}-2.md" || "$second" == "${first%/}-2/" ) ]]; then
            pass "$1 同じ分の 2 回目は -2（${second}）"
            # 1 回目の写しは 2 回目の前の中身のまま、2 回目の写しは変えた後の中身
            if [[ -n "$(sn_grep "$S/${first%/}" "second-$n")" ]]; then
                fail "$1 2 回目が 1 回目の写しを上書きした: $first"
            elif [[ -z "$(sn_grep "$S/${second%/}" "second-$n")" ]]; then
                fail "$1 2 回目の写しに変えた後の中身が無い: $second"
            else
                pass "$1 2 回目は 1 回目の写しを上書きしない（中身で確かめる）"
            fi
            return
        fi
        if [[ "${first:0:${#first}}" =~ archived-([0-9]{8}-[0-9]{4}) ]] && [[ "$second" == *"${BASH_REMATCH[1]}"* ]]; then
            break
        fi
    done
    fail "$1 2 回目の名前: 1 回目 $first / 2 回目 $second"
}

mtime_of() { "$PY" -c 'import os, sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$1"; }
fm_of() { awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f' "$1"; }

run_snapshot_tests() {
    local S="$WORK/sn" out rc copy stamp
    git_init "$S"
    mkdir -p "$S/tmp/review"
    printf -- '---\ntype: Plan Review\ntitle: 計画レビュー\ndescription: 判定\nstatus: stable\n---\n# 実装計画レビュー\n\n**総合判定**: LGTM\n' \
        >"$S/tmp/plan-review.md"
    # plan-lgtm は plan-review.md の mtime で完了を判定するので、元の mtime を動かさないことを見る
    touch -t 202601010000 "$S/tmp/plan-review.md"
    cp -p "$S/tmp/plan-review.md" "$WORK/pr.orig"

    # --- SN-file: ファイルの写し（C-16） ---
    out="$(cd "$S" && kn snapshot tmp/plan-review.md --reason s2-lgtm 2>&1)"; rc=$?
    assert_rc "SN-file snapshot は 0" 0 "$rc" "$out"
    if [[ "$out" =~ ^tmp/plan-review\.archived-([0-9]{8}-[0-9]{4})-s2-lgtm\.md$ ]]; then
        stamp="${BASH_REMATCH[1]}"
        pass "SN-file 写しの名前は <name>.archived-<YYYYMMDD-HHmm>-<reason>.md"
    else
        stamp=""
        fail "SN-file 写しの名前: $out"
    fi
    copy="$S/$out"
    assert_has "SN-file 写しは status: deprecated" "$(fm_of "$copy")" "status: deprecated"
    assert_has "SN-file 写しの後継は元のパス" "$(fm_of "$copy")" "superseded_by: tmp/plan-review.md"
    assert_has "SN-file 写しに理由" "$(fm_of "$copy")" "archived_reason: s2-lgtm"
    assert_has "SN-file 写しは元の type を保つ" "$(fm_of "$copy")" "type: Plan Review"
    assert_has "SN-file 写しは本文を保つ" "$(cat "$copy" 2>/dev/null)" "**総合判定**: LGTM"
    if [[ "$(fm_of "$copy" | grep -c '^status:')" == 1 ]]; then pass "SN-file status 行は 1 つだけ（置き換え）"; else fail "SN-file status 行の数: $(fm_of "$copy")"; fi
    if cmp -s "$WORK/pr.orig" "$S/tmp/plan-review.md"; then pass "SN-file 元の中身を変えない"; else fail "SN-file 元の中身が変わった"; fi
    assert_rc "SN-file 元の mtime を変えない" "$(mtime_of "$WORK/pr.orig")" "$(mtime_of "$S/tmp/plan-review.md")" ""

    # 同じ分にもう一度 → -2（前の写しを上書きしない。C-19）
    sn_dup "SN-file" tmp/plan-review.md
    if [[ -f "$copy" ]] && grep -q 'archived_reason: s2-lgtm' "$copy"; then pass "SN-file 名前の違う後の snapshot は前の写しを消さない"; else fail "SN-file 前の写しが消えた"; fi

    # --- SN-nofm: frontmatter の無い元（C-17） ---
    printf '# 調査: 既存の hook\n\n本文\n' >"$S/tmp/research.md"
    out="$(cd "$S" && kn snapshot tmp/research.md --reason r1 2>&1)"; rc=$?
    assert_rc "SN-nofm snapshot は 0" 0 "$rc" "$out"
    copy="$S/$out"
    assert_has "SN-nofm 登録表から type" "$(fm_of "$copy")" "type: Research"
    # `: ` を含む値は引用して書く（YAML として読める形。check は引用なしでも読むので、字面で確かめる）
    assert_has "SN-nofm H1 から title（: を含むので引用する）" "$(fm_of "$copy")" "title: '調査: 既存の hook'"
    out="$(kn index --tmp "$S/tmp" --stdout 2>&1)"
    assert_has "SN-nofm 引用した title を読み戻す（旧版の節）" "${out#*旧版（deprecated）}" "[調査: 既存の hook]"
    assert_has "SN-nofm description は元のパスと日時" "$(fm_of "$copy")" "description: tmp/research.md の "
    assert_has "SN-nofm 本文を保つ" "$(cat "$copy" 2>/dev/null)" $'---\n# 調査: 既存の hook\n\n本文'
    printf '本文だけ\n' >"$S/tmp/zzz.md"
    out="$(cd "$S" && kn snapshot tmp/zzz.md --reason r1 2>&1)"
    assert_has "SN-nofm H1 も種類も無ければ title はファイル名" "$(fm_of "$S/$out")" "title: zzz.md"
    # 旧形式（必須キーが欠ける）の元も、写しは揃った frontmatter になる
    printf -- '---\nmode: concept\ntitle: 題材\nbase_commit: abc\n---\n# 背景\n' >"$S/tmp/context.md"
    out="$(cd "$S" && kn snapshot tmp/context.md --reason r1 2>&1)"
    assert_has "SN-nofm 旧形式の写しに type を足す" "$(fm_of "$S/$out")" "type: Context"
    assert_has "SN-nofm 旧形式の写しは元のキーを保つ" "$(fm_of "$S/$out")" "base_commit: abc"

    # --- SN-dupkey: 同じキーが 2 行ある元。parse は後勝ちで読むので、置き換えたキーの 2 行目以降を残すと写しが現行に化ける ---
    printf -- '---\ntype: Research\ntitle: 重複\ndescription: d\nstatus: stable\nstatus: stable\n---\n# 重複\n' >"$S/tmp/dup.md"
    out="$(cd "$S" && kn snapshot tmp/dup.md --reason r1 2>&1)"
    if [[ "$(fm_of "$S/$out" | grep -c '^status:')" == 1 ]]; then pass "SN-dupkey status 行は 1 つだけ"; else fail "SN-dupkey status 行: $(fm_of "$S/$out")"; fi
    assert_has "SN-dupkey 写しは deprecated" "$(fm_of "$S/$out")" "status: deprecated"
    out="$(kn index --tmp "$S/tmp" --stdout 2>&1)"
    assert_has "SN-dupkey 写しは目録の旧版に載る" "${out#*## Research}" $'### 旧版（deprecated）\n\n* [重複](<dup.archived-'
    rm -f "$S/tmp/dup.md" "$S"/tmp/dup.archived-*

    # --- SN-dir: ディレクトリの写し（C-18） ---
    printf -- '---\ntype: Review Report\ntitle: 統合\ndescription: まとめ\nstatus: stable\n---\n' >"$S/tmp/review/unified.md"
    printf '# セキュリティ\n' >"$S/tmp/review/security-review.md"
    printf '{}' >"$S/tmp/review/codex-review.json"
    out="$(cd "$S" && kn snapshot tmp/review --reason r1 2>&1)"; rc=$?
    assert_rc "SN-dir snapshot は 0" 0 "$rc" "$out"
    if [[ "$out" =~ ^tmp/review\.archived-[0-9]{8}-[0-9]{4}-r1/$ ]]; then pass "SN-dir 写しは tmp/review/ の外の <dir>.archived-<stamp>-<reason>/"; else fail "SN-dir 写しの名前: $out"; fi
    copy="$S/${out%/}"
    assert_has "SN-dir 中の md の後継は元のディレクトリ" "$(fm_of "$copy/unified.md")" "superseded_by: tmp/review/"
    assert_has "SN-dir frontmatter の無い md も書き換える" "$(fm_of "$copy/security-review.md")" "superseded_by: tmp/review/"
    assert_has "SN-dir md でないファイルもそのまま写す" "$(cat "$copy/codex-review.json" 2>/dev/null)" "{}"
    # /review は毎回 tmp/review/ の中身を消して作り直す。写しは残る
    rm -rf "$S/tmp/review/"*
    if [[ -f "$copy/unified.md" ]]; then pass "SN-dir tmp/review/ を空にしても写しは残る"; else fail "SN-dir 写しが消えた"; fi
    mkdir -p "$S/tmp/review"; printf '# x\n' >"$S/tmp/review/a.md"
    sn_dup "SN-dir" tmp/review
    out="$(kn lint --tmp "$S/tmp" 2>&1)"; rc=$?
    assert_rc "SN-dir 写しはすべて lint の違反にならない" 0 "$rc" "$out"
    assert_has "SN-dir 写しは正常に数える" "$out" "review.archived-"

    # --- SN-dot: 名前を持たないコピー元（. ・..）。保存先がコピー元の中にできると、copytree が保存先自身を写し続ける ---
    local D="$WORK/sndot" arg cwd n=0 got
    git_init "$D"
    mkdir -p "$D/tmp/review/sub"
    printf '# x\n' >"$D/tmp/review/a.md"
    for arg in "tmp/review:." "$D:tmp/review/." "$D:tmp/review/" "tmp/review/sub:.."; do
        n=$((n + 1)); cwd="${arg%%:*}"; arg="${arg#*:}"
        [[ "$cwd" == /* ]] || cwd="$D/$cwd"
        out="$(cd "$cwd" && kn snapshot "$arg" --reason "dot$n" 2>&1)"; rc=$?
        assert_rc "SN-dot ${arg}（cwd ${cwd#"$D"/}）は 0" 0 "$rc" "$out"
        # . と .. は絶対パスで返るので、字面ではなく存在で確かめる
        got="${out%/}"; [[ "$got" == /* ]] || got="$cwd/$got"
        if [[ -d "$got" && "$(basename "$got")" == review.archived-*-dot$n && "$(cd "$(dirname "$got")" && pwd -P)" == "$(cd "$D/tmp" && pwd -P)" ]]; then
            pass "SN-dot ${arg} の写しはコピー元の外（tmp/review.archived-…）"
        else
            fail "SN-dot ${arg} の写しの場所: $out"
        fi
        if [[ -z "$(find "$D/tmp/review" -name '*.archived-*' 2>/dev/null)" ]]; then pass "SN-dot ${arg} はコピー元の中に写しを作らない"; else fail "SN-dot ${arg} がコピー元の中に写しを作った: $(find "$D/tmp/review" -name '*.archived-*' | head -3)"; fi
    done
    # 防御の 2 枚目: 正規化を通っても保存先の実体がコピー元の実体の下になる（ディレクトリへの symlink）なら、何も作らずに 2
    ln -s . "$D/tmp/up"
    OUT="$(cd "$D/tmp" && kn snapshot up --reason loop 2>&1)"; RC=$?
    assert_error "SN-dot 保存先がコピー元の実体の下になる symlink は 2" "up"
    if [[ -z "$(find "$D/tmp" -maxdepth 1 -name 'up.archived-*' 2>/dev/null)" ]]; then pass "SN-dot 拒否したときは保存先を作らない"; else fail "SN-dot 拒否したのに保存先がある"; fi
    rm -f "$D/tmp/up"

    # --- SN-reason: 理由の正規化（C-20） ---
    printf '%s' "$FM_FULL" >"$S/tmp/plan.md"
    out="$(cd "$S" && kn snapshot tmp/plan.md --reason 'a/b c' 2>&1)"
    if [[ "$out" =~ -a-b-c\.md$ ]]; then pass "SN-reason / と空白は -"; else fail "SN-reason / と空白: $out"; fi
    assert_has "SN-reason archived_reason には元の文を残す" "$(fm_of "$S/$out")" "archived_reason: a/b c"
    if [[ "$(stat -f %Lp "$S/tmp/index.md" 2>/dev/null || stat -c %a "$S/tmp/index.md")" == "$(umask -S >/dev/null; printf '%o' $((0666 & ~0$(umask))))" ]]; then
        pass "SN-reason 目録の権限は umask に従う"
    else
        fail "SN-reason 目録の権限: $(ls -l "$S/tmp/index.md")"
    fi
    out="$(cd "$S" && kn snapshot tmp/plan.md --reason "$(printf 'x%.0s' $(seq 1 60))" 2>&1)"
    if [[ "$out" =~ -x{40}\.md$ ]]; then pass "SN-reason 40 文字で切る"; else fail "SN-reason 40 文字: $out"; fi
    # 名前は許可リスト（語の文字・. ・-）で正規化する。値は要るときだけ引用し、写しが lint の違反にならない
    out="$(cd "$S" && kn snapshot tmp/plan.md --reason '| 理由' 2>&1)"
    if [[ "$out" =~ archived-[0-9]{8}-[0-9]{4}-理由\.md$ ]]; then pass "SN-reason 記号は名前に出ない（| 理由 → 理由）"; else fail "SN-reason 記号: $out"; fi
    assert_has "SN-reason | で始まる理由は引用する" "$(fm_of "$S/$out")" "archived_reason: '| 理由'"
    # 読み戻し: 引用の中の '' は ' に戻る（書き手と対）。H1 に ' と : を含む元の写しを目録で読む
    printf "# it's: x\n" >"$S/tmp/quote.md"
    out="$(cd "$S" && kn snapshot tmp/quote.md --reason r1 2>&1)"
    assert_has "SN-reason '' を含む title を書く" "$(fm_of "$S/$out")" "title: 'it''s: x'"
    assert_has "SN-reason '' を ' に読み戻す（目録）" "$(kn index --tmp "$S/tmp" --stdout 2>&1)" "* [it's: x](<quote.archived-"
    rm -f "$S/tmp/quote.md" "$S"/tmp/quote.archived-*
    out="$(cd "$S" && kn snapshot tmp/plan.md --reason "it's: x" 2>&1)"
    copy="$S/$out"
    assert_has "SN-reason ' は '' にして引用する" "$(fm_of "$copy")" "archived_reason: 'it''s: x'"
    # 置き換えの分岐: 既に archived_reason を持つ写しをもう一度写すと、その行を置き換える
    out="$(cd "$S" && kn snapshot "${copy#"$S"/}" --reason "a: b" 2>&1)"
    assert_has "SN-reason 置き換えた値も引用する" "$(fm_of "$S/$out")" "archived_reason: 'a: b'"
    out="$(kn lint --tmp "$S/tmp" 2>&1)"; rc=$?
    assert_rc "SN-reason 引用した写しも lint の違反にならない" 0 "$rc" "$out"
    OUT="$(cd "$S" && kn snapshot tmp/plan.md --reason '' 2>&1)"; RC=$?
    assert_error "SN-reason 空の理由は 2" "reason"
    OUT="$(cd "$S" && kn snapshot tmp/plan.md --reason ' / ' 2>&1)"; RC=$?
    assert_error "SN-reason 正規化で空になる理由も 2" "reason"

    # --- SN-args: 無いパスは 2 で、ほかのパスも写さない ---
    local before after
    before="$(ls "$S/tmp" | wc -l)"
    OUT="$(cd "$S" && kn snapshot tmp/plan.md tmp/no-such.md --reason r9 2>&1)"; RC=$?
    assert_error "SN-args 無いパスは 2" "no-such.md"
    after="$(ls "$S/tmp" | wc -l)"
    assert_rc "SN-args 1 つでも無ければ何も写さない" "$before" "$after" "$(ls "$S/tmp")"
    out="$(kn snapshot "$S/tmp/plan.md" --reason abs 2>&1)"
    if [[ "$out" == "$S/tmp/plan.archived-"*"-abs.md" ]]; then pass "SN-args 絶対パスで渡せば絶対パスで返す"; else fail "SN-args 絶対パス: $out"; fi

    # --- SN-index: 写しの後に目録を回し直す。目録の失敗では止めない（C-21） ---
    assert_has "SN-index 目録の旧版に写しが載る" "$(cat "$S/tmp/index.md" 2>/dev/null)" "(<plan-review.archived-"
    local O="$WORK/sn-foreign" err
    git_init "$O"; mkdir -p "$O/tmp"
    printf '%s' "$FM_FULL" >"$O/tmp/plan.md"
    printf '# 手で書いた目録\n' >"$O/tmp/index.md"
    out="$(cd "$O" && kn snapshot tmp/plan.md --reason r1 2>"$WORK/sn.err")"; rc=$?
    err="$(cat "$WORK/sn.err")"
    assert_rc "SN-index 他人の index.md があっても写しができれば 0" 0 "$rc" "$out / $err"
    if [[ -f "$O/$out" ]]; then pass "SN-index 写しはできている"; else fail "SN-index 写しが無い: $out"; fi
    assert_has "SN-index 目録の失敗を stderr に出す" "$err" "index.md"
    if [[ "$(printf '%s\n' "$err" | grep -c .)" == 1 ]]; then pass "SN-index stderr は 1 行"; else fail "SN-index stderr: $err"; fi
    assert_has "SN-index 他人の index.md は変えない" "$(cat "$O/tmp/index.md")" "# 手で書いた目録"
}

# ============================================================ TP: skill の出力の雛形

# tmp/ に md を書く雛形の一覧（雛形のあるファイル|書き先）。1 つの雛形が複数の書き先を持つときは行を分ける。
# 目印（<!-- tmp-frontmatter: 書き先 … -->）の組の集合とこの表が一致することを見るので、雛形を足したら両方を直す
WRITERS="$(cat <<'EOF'
shared/agents/01-core-development/documenter.md|tmp/doc-sync-report.md
shared/skills/ask/SKILL.md|tmp/research.md
shared/skills/blog/SKILL.md|tmp/blog-draft.md
shared/skills/brief/reference/entry.md|tmp/context.md
shared/skills/brief/reference/modes/bug.md|tmp/context.md
shared/skills/brief/reference/modes/concept.md|tmp/context.md
shared/skills/brief/reference/modes/implement.md|tmp/context.md
shared/skills/brief/reference/modes/refactor.md|tmp/context.md
shared/skills/code-comments/SKILL.md|tmp/comment-review.md
shared/skills/coupling-audit/SKILL.md|tmp/coupling-audit.md
shared/skills/coupling-gate/SKILL.md|tmp/coupling-gate.md
shared/skills/coupling-plan-diff/SKILL.md|tmp/coupling-plan-diff.md
shared/skills/coupling-precheck/SKILL.md|tmp/coupling-precheck.md
shared/skills/design/reference/plan-template.md|tmp/plan.md
shared/skills/fix/reference/category-examples.md|tmp/fixes.md
shared/skills/fix/reference/fix-plan-template.md|tmp/fix-plan.md
shared/skills/grill/SKILL.md|tmp/grill.md
shared/skills/grill/reference/business-scenario.md|tmp/scenario.md
shared/skills/grill/reference/business-scenario.md|tmp/scenario.md
shared/skills/implement/reference/agent-selection.md|tmp/step-{n}-{agent-name}-result.md
shared/skills/integration-test-run/reference/report-template.md|tmp/integration-test-results.md
shared/skills/integration-test-scenario/reference/scenario-template.md|tmp/integration-test-scenario.md
shared/skills/outline/SKILL.md|tmp/outline.md
shared/skills/review-plan/reference/report-template.md|tmp/plan-review.md
shared/skills/review-strategic-ddd/reference/review-checklist.md|tmp/strategic-ddd-review.md
shared/skills/review/SKILL.md|tmp/review/_ci-failures.md
shared/skills/review/SKILL.md|tmp/review/_overview.md
shared/skills/review/SKILL.md|tmp/review/{agent-name}-review.md
shared/skills/review/reference/edge-case-reverification.md|tmp/review/_edge-{category}-review.md
shared/skills/review/reference/unified-report-template.md|tmp/review/unified.md
shared/skills/series-sync/reference/series-format.md|tmp/context.md
shared/skills/series-sync/reference/series-format.md|tmp/handoff/<repo>.md
shared/skills/series-sync/reference/series-format.md|tmp/series.draft.md
shared/skills/series-sync/reference/series-format.md|tmp/series.md
shared/skills/spec-check/SKILL.md|tmp/spec-check.md
shared/skills/strategic-ddd/reference/output-template.md|tmp/strategic-ddd.md
EOF
)"

# 目印ごとに「##MARK ファイル:行 書き先…」「フェンスの中の最初の --- ブロック」「##END」を出す。
# 最初のブロックを取るのは、雛形がサブエージェントへの指示のフェンスの中にある場合（edge の再検証）があるため。
# 目印の次の行がフェンスの開始でなければ「##BADFENCE ファイル:行」
extract_templates() {
    local f
    while IFS= read -r f; do
        awk -v F="${f#"$REPO_ROOT"/}" '
            pending {
                if (match($0, /^(`{3,}|~{3,})/)) { fence = substr($0, RSTART, RLENGTH); infence = 1; seen = 0; infm = 0 }
                else { print "##BADFENCE " F ":" mline }
                pending = 0; next
            }
            infence {
                if (index($0, fence) == 1 && $0 ~ /^[`~]+[[:space:]]*$/) { infence = 0; print "##END"; next }
                if (!seen && $0 == "---") { seen = 1; infm = 1; print; next }
                if (infm) { print; if ($0 == "---") infm = 0 }
                next
            }
            /^<!-- tmp-frontmatter: .* -->$/ {
                t = $0; sub(/^<!-- tmp-frontmatter: /, "", t); sub(/ -->$/, "", t)
                print "##MARK " F ":" NR " " t; pending = 1; mline = NR
            }
        ' "$f"
    done < <(grep -rl --include='*.md' '^<!-- tmp-frontmatter: ' "$REPO_ROOT/shared" | sort)
}

run_template_tests() {
    local R="$WORK/tp" all line loc targets fm t path out rc types marks=""
    git_init "$R"
    mkdir -p "$R/tmp"
    all="$(extract_templates)"
    types="$(kn types | cut -f1)"
    if [[ -z "$all" ]]; then fail "TP 目印が 1 つも無い（抽出自体を疑う）"; return; fi
    while IFS= read -r line; do
        case "$line" in
            "##BADFENCE "*) fail "TP 目印の次の行がフェンスの開始でない: ${line#\#\#BADFENCE }" ;;
            "##MARK "*) loc="${line#\#\#MARK }"; targets="${loc#* }"; loc="${loc%% *}"; fm="" ;;
            "##END")
                for t in $targets; do
                    marks+="${loc%%:*}|${t}"$'\n'
                    # プレースホルダ（{...}・<...>）を固定の値にして、書き先のパスで check に通す
                    path="$R/$(printf '%s' "$t" | sed -E 's/\{[^}]*\}/x/g; s/<[^>]*>/x/g')"
                    out="$(printf '%s\n' "$fm" | sed -E 's/\{[^}]*\}/x/g; s/<[^>]*>/x/g' | kn check --path "$path" --op write 2>&1)"; rc=$?
                    assert_rc "TP $loc → $t の雛形は check を通る" 0 "$rc" "$out"
                done
                local ty
                ty="$(printf '%s\n' "$fm" | sed -n 's/^type:[[:space:]]*//p' | head -1)"
                if printf '%s\n' "$types" | grep -qxF "$ty"; then pass "TP $loc の type（${ty}）は登録表にある"; else fail "TP $loc の type が登録表に無い: '$ty'"; fi
                ;;
            *) fm+="$line"$'\n' ;;
        esac
    done <<<"$all"

    # 書き手の一覧のすべての組に目印がある（目印を消すと、その雛形が上の検査から黙って外れるため）。
    # 逆向き（目印があるのに一覧に無い）は見ない。一覧を目印に合わせて写し直すだけの検査になる。
    # 件数でも比べる（同じ組の雛形が 2 つあるファイルでは、片方の目印を消しても組の集合は変わらないため。一覧に同じ行を 2 つ書く）
    local want got missing
    want="$(printf '%s\n' "$WRITERS" | grep -v '^$' | sort)"
    got="$(printf '%s' "$marks" | grep -v '^$' | sort)"
    missing="$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$got"))"
    if [[ -n "$want" && -z "$missing" ]]; then
        pass "TP 書き手の一覧の $(printf '%s\n' "$want" | wc -l | tr -d ' ') 組すべてに目印がある"
    else
        fail "TP 目印の無い書き手: $(printf '%s' "$missing" | tr '\n' ' ')"
    fi

    # 登録表の種類のうち、どの雛形にも出てこないものは warn（片方だけ直して黙ってずれる型を見えるようにする）
    local name used
    used="$(printf '%s\n' "$all" | sed -n 's/^type:[[:space:]]*//p' | sort -u)"
    while IFS= read -r name; do
        printf '%s\n' "$used" | grep -qxF "$name" || echo "  [WARN] ${LABEL}TP 登録表の種類 $name を使う雛形が無い"
    done < <(printf '%s\n' "$types" | sort -u)
}

# ============================================================ 実行

# python3 と /usr/bin/python3 が別物なら両方で全件を回す（3.9 で動くことの検証）
PYS=(python3)
if [[ -x /usr/bin/python3 ]] && \
    [[ "$(/usr/bin/python3 -c 'import sys; print(sys.version)')" != "$(python3 -c 'import sys; print(sys.version)')" ]]; then
    PYS+=(/usr/bin/python3)
fi

if [[ ! -f "$KN" ]]; then
    echo "test-knowledge.sh: 検査対象が見つからない: $KN" >&2
fi

run_no=0
for PY in "${PYS[@]}"; do
    run_no=$((run_no + 1))
    WORK="$BASE/run-$run_no"
    mkdir -p "$WORK"
    LABEL="[$("$PY" -c 'import sys; print("py%d.%d" % sys.version_info[:2])')] "
    echo "== ${PY}（$("$PY" --version 2>&1)）=="
    run_check_tests
    run_lint_index_tests
    run_snapshot_tests
    run_template_tests
done

echo
echo "${pass_count} passed / ${fail_count} failed（python: ${PYS[*]}）"
[[ "$fail_count" -eq 0 ]] || exit 1
