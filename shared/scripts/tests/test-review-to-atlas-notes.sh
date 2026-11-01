#!/usr/bin/env bash
# review-to-atlas-notes.py（/review の tmp/review/unified.md → atlas.nvim の Notes）の挙動テスト。
#
# 守りたいのは「黙って通さない」こと: 書式が変わって 0 件になる・HEAD がずれて別の行に付く・
# 別の PR や古いレポートを書き込む・2 回の実行で note が倍になる・atlas-notes の失敗を握りつぶす。
# どれも書き込みは成功して見えるので、通常の動作確認では気づけない。
#
# GitHub にも本物の atlas にもつながない。PATH の先頭に偽の gh を置き、atlas-notes は偽物を
# --atlas-notes で渡して、add の呼び出しを記録で数える。偽物は想定外の引数で非 0 を返す
# （寛容な偽物だと、本物が受け付けない呼び方でも全件が通るため）。git は一時 repo を実際に作る。
#
# スクリプトは /usr/bin/python3（3.9）でも動かす前提なので、python3 と /usr/bin/python3 が
# 別物なら両方で全件を回す。HOME は差し替えない（mise の shim が壊れるため）。
#
# 起動: bash shared/scripts/tests/test-review-to-atlas-notes.sh

# set -e は使わない。1 件目の失敗で残りが走らなくなると、Red で全件の失敗を確かめられない
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TARGET="$REPO_ROOT/shared/scripts/review-to-atlas-notes.py"

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

assert_eq() {  # $1=ラベル, $2=期待値, $3=実際の値
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1"
        echo "       期待: ${2:-（空）}" >&2
        echo "       実際: ${3:-（空）}" >&2
    fi
}
assert_contains() {  # $1=ラベル, $2=実出力, $3=期待する部分文字列
    if [[ "$2" == *"$3"* ]]; then
        pass "$1"
    else
        fail "$1"
        echo "       期待する部分文字列: $3" >&2
        printf '%s\n' "$2" | tail -n 8 | sed 's/^/         /' >&2
    fi
}
assert_not_contains() {  # $1=ラベル, $2=実出力, $3=含まれてはいけない部分文字列
    if [[ "$2" != *"$3"* ]]; then
        pass "$1"
    else
        fail "$1"
        echo "       含まれてはいけない部分文字列: $3" >&2
    fi
}

# --- 偽のコマンド ---------------------------------------------------------
# 偽の gh: `gh pr view <pr> --json number,url,headRefOid` だけを受け付け、$WORK/gh.json を返す
make_fakes() {
    mkdir -p "$WORK/bin"
    cat >"$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DIR/gh.calls"
if [[ "${FAKE_GH_RC:-0}" != 0 ]]; then
    echo "gh: fake failure (HTTP 404)" >&2
    exit "$FAKE_GH_RC"
fi
if [[ "$1" == pr && "$2" == view && $# -eq 5 && "$4" == --json && "$5" == number,url,headRefOid ]]; then
    cat "$FAKE_DIR/gh.json"
    exit 0
fi
echo "fake gh: unexpected args: $*" >&2
exit 99
EOF
    chmod +x "$WORK/bin/gh"
    # 偽の atlas-notes: list は $FAKE_DIR/list.out を返す。add は引数を JSON 1 行で記録する
    cat >"$WORK/atlas-notes" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
d = os.environ["FAKE_DIR"]
args = sys.argv[1:]
with open(os.path.join(d, "notes.calls"), "a") as f:
    f.write(json.dumps({"argv": args, "appname": os.environ.get("NVIM_APPNAME"), "self": sys.argv[0]}) + "\n")
if args[:1] == ["list"] and len(args) == 3 and args[1] == "--target":
    if os.environ.get("FAKE_LIST_RC", "0") != "0":
        sys.stderr.write("atlas-notes: cannot open store (fake)\n")
        sys.exit(int(os.environ["FAKE_LIST_RC"]))
    with open(os.path.join(d, "list.out")) as f:
        sys.stdout.write(f.read())
    sys.exit(0)
if args[:1] == ["add"]:
    opts = {}
    rest = args[1:]
    if len(rest) % 2:
        sys.stderr.write("atlas-notes: expected --name value arguments\n")
        sys.exit(1)
    for k, v in zip(rest[0::2], rest[1::2]):
        if not k.startswith("--"):
            sys.stderr.write("atlas-notes: expected --name value arguments\n")
            sys.exit(1)
        opts[k[2:]] = v
    allowed = {"target", "commit", "file", "start-line", "end-line", "body", "type", "context"}
    unknown = set(opts) - allowed
    missing = {"target", "commit", "file", "start-line", "body"} - set(opts)
    if unknown or missing:
        sys.stderr.write("atlas-notes: bad options %s %s\n" % (sorted(unknown), sorted(missing)))
        sys.exit(1)
    n = sum(1 for l in open(os.path.join(d, "notes.calls")) if json.loads(l)["argv"][:1] == ["add"])
    if os.environ.get("FAKE_ADD_SLEEP"):
        import time
        time.sleep(float(os.environ["FAKE_ADD_SLEEP"]))
    fail_at = int(os.environ.get("FAKE_ADD_FAIL_AT", "0"))
    if fail_at and n >= fail_at:
        sys.stderr.write("atlas-notes: storage is locked (fake)\n")
        sys.exit(1)
    print(json.dumps({"id": "n%d" % n}))
    sys.exit(0)
sys.stderr.write("fake atlas-notes: unexpected args: %r\n" % (args,))
sys.exit(99)
EOF
    chmod +x "$WORK/atlas-notes"
}

# 一時 repo（HEAD のコミットを 1 つ）。headRefOid は既定で HEAD
make_repo() {  # $1=名前 → repo のパス
    local r="$WORK/repo-$1"
    mkdir -p "$r/src" "$r/tmp/review"
    git -C "$r" init -q
    git -C "$r" config user.email test@example.com
    git -C "$r" config user.name test-review-notes
    git -C "$r" config commit.gpgsign false
    # 200 行。正常系のレポートの行番号（L7・L15・L42-50・L100 など）がファイルの範囲に入るように
    seq 200 >"$r/src/foo.ts"
    git -C "$r" add src/foo.ts
    # コミット時刻を過去に固定する。鮮度は SHA で判定し mtime に依存しないことを、T-R9c が mtime をさらに古くして確かめる
    GIT_COMMITTER_DATE="2026-01-01T00:00:00" GIT_AUTHOR_DATE="2026-01-01T00:00:00" git -C "$r" commit -q -m init
    echo "$r"
}

head_of() { git -C "$1" rev-parse HEAD; }

set_pr() {  # $1=headRefOid, $2=number（既定 38）
    printf '{"number":%s,"url":"https://github.com/o/r/pull/%s","headRefOid":"%s"}\n' "${2:-38}" "${2:-38}" "$1" >"$WORK/gh.json"
}
set_list() {  # $1=notes 配列の JSON（既定 []）
    printf '{"target":"github.com/o/r/pr-38","notes":%s}\n' "${1:-[]}" >"$WORK/list.out"
}
reset_calls() { : >"$WORK/notes.calls"; : >"$WORK/gh.calls"; }

# add の呼び出しの数と、n 番目（1 始まり）の --name の値
add_count() { "$PY" -c 'import json,sys; print(sum(1 for l in open(sys.argv[1]) if json.loads(l)["argv"][:1]==["add"]))' "$WORK/notes.calls"; }
add_opt() {  # $1=n, $2=name
    "$PY" -c '
import json, sys
adds = [json.loads(l)["argv"] for l in open(sys.argv[1]) if json.loads(l)["argv"][:1] == ["add"]]
a = adds[int(sys.argv[2]) - 1][1:] if len(adds) >= int(sys.argv[2]) else []
d = dict(zip(a[0::2], a[1::2]))
print(d.get("--" + sys.argv[3], "<none>"))' "$WORK/notes.calls" "$1" "$2"
}
any_opt() {  # $1=name → いずれかの add にその option があれば yes
    "$PY" -c '
import json, sys
for l in open(sys.argv[1]):
    a = json.loads(l)["argv"]
    if a[:1] == ["add"] and ("--" + sys.argv[2]) in a[1::2]:
        print("yes"); break
else:
    print("no")' "$WORK/notes.calls" "$1"
}

# スクリプトを repo の中で走らせる。stdout・stderr・rc を $WORK に残す
run_script() {  # $1=repo, $2...=引数
    local r="$1"
    shift
    (cd "$r" && PATH="$WORK/bin:$PATH" FAKE_DIR="$WORK" "$PY" "$TARGET" "$@") >"$WORK/out" 2>"$WORK/err"
    echo $? >"$WORK/rc"
}
rc() { cat "$WORK/rc"; }
out() { cat "$WORK/out"; }
err() { cat "$WORK/err"; }

# 実際のテンプレート（shared/skills/review/reference/unified-report-template.md）の形のレポート
write_report() {  # $1=repo, $2=ヘッダの PR 行（既定 **PR #38**: title）, $3=HEAD 行の SHA（既定 repo の HEAD。空なら行を書かない）, 標準入力=本文（ヘッダの後）
    local r="$1" header="${2-**PR #38**: test pr}" sha="${3-$(head_of "$1")}"
    {
        printf '%s\n' '---' 'type: Code Review' 'title: test' 'description: test' 'status: stable' '---' \
            '# コードレビューレポート' ''
        [[ -n "$header" ]] && printf '%s\n' "$header"
        printf '%s\n' '**ブランチ**: `feat` → `main`'
        [[ -n "$sha" ]] && printf '**HEAD**: `%s`\n' "$sha"
        printf '%s\n' '**レビュー日**: 2026-10-31' ''
        cat
    } >"$r/tmp/review/unified.md"
    touch "$r/tmp/review/unified.md"
}

FULL_BODY='## 💡 設計判断（Human Review 推奨）

### 設計判断

- **H-1. 状態を二重に持っている** — `src/foo.ts:L7`
  キャッシュと store の両方に同じ値がある。
  どちらを正とするかを決めたい。

---

## ❌ Critical Issues（修正必須）

### C-1. null を返す経路がある
**エージェント**: backend-developer | **確信度**: High | **カテゴリ**: bug
**ファイル**: `src/foo.ts:L42-50`

user が見つからないと null を返し、呼び出し側で落ちる。

```ts
// ❌ 現状
return null
```

---

## ⚠️ Minor Issues（改善提案）

### M-1. 名前が曖昧
**エージェント**: reviewer | **確信度**: Medium | **カテゴリ**: naming
**ファイル**: `src/foo.ts:L15`

data という名前は中身を表さない。

---

## ℹ️ Info & Questions（確認事項）

### I-1. 例外の扱いを確認したい
**ファイル**: `src/foo.ts:L100`

握りつぶしてよいか。
'

one_c_report() {  # $1=repo
    write_report "$1" <<'EOF'
## ❌ Critical Issues（修正必須）

### C-1. null を返す経路がある
**エージェント**: backend-developer | **確信度**: High | **カテゴリ**: bug
**ファイル**: `src/foo.ts:L42-50`

user が見つからないと null を返し、呼び出し側で落ちる。
EOF
}

run_tests() {
    make_fakes
    local R H out_s

    # T-R1: C・M・I・H を 1 件ずつ
    R="$(make_repo r1)"; H="$(head_of "$R")"; set_pr "$H"; set_list; reset_calls
    printf '%s' "$FULL_BODY" | write_report "$R"
    run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes"
    assert_eq "T-R1 exit 0" "0" "$(rc)"
    assert_eq "T-R1 add が 4 回" "4" "$(add_count)"
    # 順はレポートの出現順（H → C → M → I）
    assert_eq "T-R1 H の type は note" "note" "$(add_opt 1 type)"
    assert_eq "T-R1 C の type は issue" "issue" "$(add_opt 2 type)"
    assert_eq "T-R1 M の type は suggestion" "suggestion" "$(add_opt 3 type)"
    assert_eq "T-R1 I の type は note" "note" "$(add_opt 4 type)"
    assert_eq "T-R1 --commit は headRefOid" "$H" "$(add_opt 2 commit)"
    assert_eq "T-R1 --target は PR の URL" "https://github.com/o/r/pull/38" "$(add_opt 2 target)"
    assert_eq "T-R1 --file は repo 相対のパス" "src/foo.ts" "$(add_opt 2 file)"
    assert_eq "T-R1 L42-50 の start" "42" "$(add_opt 2 start-line)"
    assert_eq "T-R1 L42-50 の end" "50" "$(add_opt 2 end-line)"
    assert_eq "T-R1 単一行 L15 の end は start と同じ" "15" "$(add_opt 3 end-line)"
    out_s="$(add_opt 2 body)"
    assert_contains "T-R1 C の body に [C-1] タイトル" "$out_s" "[C-1] null を返す経路がある"
    assert_contains "T-R1 C の body に詳細説明" "$out_s" "user が見つからないと null を返し"
    assert_not_contains "T-R1 C の body にメタデータ（エージェント）を入れない" "$out_s" "エージェント"
    assert_not_contains "T-R1 C の body にメタデータ（ファイル）を入れない" "$out_s" "**ファイル**"
    assert_not_contains "T-R1 C の body にコードブロックを入れない" "$out_s" "return null"
    assert_contains "T-R1 M の body に詳細説明" "$(add_opt 3 body)" "data という名前は中身を表さない"
    assert_contains "T-R1 H の body に [H-1] タイトル" "$(add_opt 1 body)" "[H-1] 状態を二重に持っている"
    assert_contains "T-R1 H の body にインデントされた説明" "$(add_opt 1 body)" "キャッシュと store の両方に"
    assert_contains "T-R1 H の body に説明の 2 行目も入れる" "$(add_opt 1 body)" "どちらを正とするかを決めたい"
    assert_contains "T-R1 I の body に詳細説明" "$(add_opt 4 body)" "握りつぶしてよいか"
    assert_eq "T-R1 --context は渡さない" "no" "$(any_opt context)"
    assert_contains "T-R1 件数を出す" "$(out)" "added 4"

    # T-R2: HEAD が headRefOid と違う
    R="$(make_repo r2)"; H="$(head_of "$R")"; set_pr "0123456789abcdef0123456789abcdef01234567"; set_list; reset_calls
    one_c_report "$R"
    run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes"
    assert_eq "T-R2 HEAD のずれは exit 1" "1" "$(rc)"
    assert_eq "T-R2 add は 0 回" "0" "$(add_count)"
    assert_contains "T-R2 HEAD の sha を出す" "$(err)" "$H"
    assert_contains "T-R2 headRefOid を出す" "$(err)" "0123456789abcdef0123456789abcdef01234567"

    # T-R3: 見出しの書式が変わって 0 件
    R="$(make_repo r3)"; set_pr "$(head_of "$R")"; set_list; reset_calls
    write_report "$R" <<'EOF'
## ❌ Critical Issues（修正必須）

#### C-1: null を返す経路がある
ファイル: src/foo.ts:L42
EOF
    run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes"
    assert_eq "T-R3 0 件は exit 1" "1" "$(rc)"
    assert_contains "T-R3 0 件と出す" "$(err)" "0 件"
    assert_eq "T-R3 add は 0 回" "0" "$(add_count)"

    # T-R4: 行番号の無い参照・絶対パス・.. を含むパスは skip し、ID を出す
    R="$(make_repo r4)"; set_pr "$(head_of "$R")"; set_list; reset_calls
    write_report "$R" <<'EOF'
### アーキテクチャ統一性

- **H-1. 行番号が無い** — `src/foo.tsx (ComponentName)`
  既存パターンとの一貫性。
- **H-2. 絶対パス** — `/etc/passwd:L1`
  外のファイル。
- **H-3. 親へ出る** — `src/../../x.ts:L3`
  repo の外。
- **H-4. 正しい** — `src/foo.ts:L9`
  これは付く。
- **H-5. 範囲が逆** — `src/foo.ts:L50-42`
  開始が終了より後。
EOF
    run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes"
    assert_eq "T-R4 1 件でも追加できれば exit 0" "0" "$(rc)"
    assert_eq "T-R4 add は正しい 1 件だけ" "1" "$(add_count)"
    assert_eq "T-R4 追加したのは H-4" "9" "$(add_opt 1 start-line)"
    assert_contains "T-R4 行番号の無い H-1 を ID で出す" "$(out)" "H-1"
    assert_contains "T-R4 行番号の無い H-1 は「行番号が無い」" "$(out)" "H-1 src/foo.tsx (ComponentName) — 行番号が無い"
    assert_contains "T-R4 絶対パスの H-2 を ID で出す" "$(out)" "H-2"
    assert_contains "T-R4 .. を含む H-3 を ID で出す" "$(out)" "H-3"
    assert_contains "T-R4 範囲が逆の H-5 を ID で出す" "$(out)" "H-5"
    assert_contains "T-R4 skip の件数を出す" "$(out)" "skipped (no line) 4"
    # 全件が skip（追加 0・重複 0）なら exit 1（書き込むものが無いのに成功に見せない）
    reset_calls
    write_report "$R" <<'EOF'
- **H-1. 行番号が無い** — `src/foo.tsx (ComponentName)`
  既存パターンとの一貫性。
EOF
    run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes"
    assert_eq "T-R4 全件が skip なら exit 1" "1" "$(rc)"

    # T-R5: 重複は 5 項目すべてが一致するときだけ skip する
    R="$(make_repo r5)"; H="$(head_of "$R")"; set_pr "$H"; reset_calls
    one_c_report "$R"
    body="$(printf '[C-1] null を返す経路がある\n\nuser が見つからないと null を返し、呼び出し側で落ちる。')"
    note() {  # $1=file_path, $2=commit, $3=start_line, $4=end_line, $5=body → note の JSON
        "$PY" -c 'import json,sys; a=sys.argv; print(json.dumps([{"id":"x","file_path":a[1],"commit":a[2],"start_line":int(a[3]),"end_line":int(a[4]),"body":a[5],"type":"issue","resolved":False}]))' "$@"
    }
    set_list "$(note src/foo.ts "$H" 42 50 "$body")"
    run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes"
    assert_eq "T-R5 全件が重複なら exit 0" "0" "$(rc)"
    assert_eq "T-R5 重複は add しない" "0" "$(add_count)"
    assert_contains "T-R5 重複の件数を出す" "$(out)" "skipped (duplicate) 1"
    # 5 項目を 1 つずつ変える（どれか 1 つでも違えば別の指摘。鍵から 1 つ落とす回帰を捕まえる）
    local kind
    for kind in file_path commit start_line end_line body; do
        reset_calls
        case "$kind" in
            file_path) set_list "$(note src/bar.ts "$H" 42 50 "$body")" ;;
            commit) set_list "$(note src/foo.ts fedcba9876543210fedcba9876543210fedcba98 42 50 "$body")" ;;
            start_line) set_list "$(note src/foo.ts "$H" 41 50 "$body")" ;;
            end_line) set_list "$(note src/foo.ts "$H" 42 51 "$body")" ;;
            body) set_list "$(note src/foo.ts "$H" 42 50 "[C-1] 別の指摘")" ;;
        esac
        run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes"
        assert_eq "T-R5 $kind だけが違う note は重複にしない" "1" "$(add_count)"
    done
    # list の出力が JSON でない → exit 1（空の一覧として扱うと重複の判定が黙って外れる）
    reset_calls; printf 'not json\n' >"$WORK/list.out"
    run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes"
    assert_eq "T-R5 list が JSON でなければ exit 1" "1" "$(rc)"
    assert_eq "T-R5 list が JSON でなければ add は 0 回" "0" "$(add_count)"

    # T-R6: atlas-notes の失敗・不在、gh の失敗
    R="$(make_repo r6)"; set_pr "$(head_of "$R")"; set_list; reset_calls
    printf '%s' "$FULL_BODY" | write_report "$R"
    (export FAKE_ADD_FAIL_AT=2; run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes")
    assert_eq "T-R6 add の途中の失敗は exit 1" "1" "$(rc)"
    assert_contains "T-R6 atlas-notes の stderr を転記する" "$(err)" "storage is locked (fake)"
    assert_contains "T-R6 失敗までに追加した件数を出す" "$(out)" "added 1"
    reset_calls
    run_script "$R" --pr 38 --atlas-notes "$WORK/no-such/atlas-notes"
    assert_eq "T-R6 atlas-notes が無ければ exit 1" "1" "$(rc)"
    assert_contains "T-R6 探したパスを出す" "$(err)" "$WORK/no-such/atlas-notes"
    reset_calls
    (export FAKE_GH_RC=1; run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes")
    assert_eq "T-R6 gh の失敗は exit 1" "1" "$(rc)"
    assert_contains "T-R6 gh の stderr を転記する" "$(err)" "fake failure (HTTP 404)"
    assert_eq "T-R6 gh の失敗では add は 0 回" "0" "$(add_count)"

    # T-R7: --dry-run は書き込まない
    R="$(make_repo r7)"; set_pr "$(head_of "$R")"; set_list; reset_calls
    one_c_report "$R"
    run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes" --dry-run
    assert_eq "T-R7 --dry-run は exit 0" "0" "$(rc)"
    assert_eq "T-R7 --dry-run は add 0 回" "0" "$(add_count)"
    assert_contains "T-R7 予定の一覧を出す" "$(out)" "C-1"
    assert_contains "T-R7 予定に場所を出す" "$(out)" "src/foo.ts:42-50"
    # 全件が skip でも --dry-run は書き込まないので exit 0（予定の確認に使う）
    reset_calls
    write_report "$R" <<'EOF'
- **H-1. 行番号が無い** — `src/foo.tsx (ComponentName)`
  既存パターンとの一貫性。
EOF
    run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes" --dry-run
    assert_eq "T-R7 全件が skip でも --dry-run は exit 0" "0" "$(rc)"
    assert_contains "T-R7 skip した ID を出す" "$(out)" "H-1"

    # T-R8: ヘッダの PR 番号が違う・無い
    R="$(make_repo r8)"; set_pr "$(head_of "$R")"; set_list; reset_calls
    one_c_report "$R"
    sed -n '/^## ❌/,$p' "$R/tmp/review/unified.md" >"$WORK/r8.body"
    write_report "$R" '**PR #39**: other' <"$WORK/r8.body"
    run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes"
    assert_eq "T-R8 別の PR のレポートは exit 1" "1" "$(rc)"
    assert_eq "T-R8 別の PR のレポートでは add 0 回" "0" "$(add_count)"
    assert_contains "T-R8 レポートの PR 番号を出す" "$(err)" "PR #39"
    reset_calls
    write_report "$R" '' <"$WORK/r8.body"
    run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes"
    assert_eq "T-R8 PR 番号の無いレポートは exit 1" "1" "$(rc)"
    assert_eq "T-R8 PR 番号の無いレポートでは add 0 回" "0" "$(add_count)"
    # rc だけだと、検査が消えても別の例外（None の書式化）で exit 1 になって通る
    assert_contains "T-R8 PR 番号が無いと出す" "$(err)" "PR 番号（**PR #N**）がありません"
    assert_not_contains "T-R8 PR 番号の欠如で例外を出さない" "$(err)" "Traceback"

    # T-R9a（regression）: レポートが別のコミットのレビュー。mtime は新しくても書き込まない
    # （mtime は同じ秒のコミットやコピーで新しくなり、古い行番号の note が今のコードに付いた）
    R="$(make_repo r9)"; H="$(head_of "$R")"; set_pr "$H"; set_list; reset_calls
    local OTHER=0123456789abcdef0123456789abcdef01234567
    one_c_report "$R"
    sed -n '/^## ❌/,$p' "$R/tmp/review/unified.md" >"$WORK/r9.body"
    write_report "$R" '**PR #38**: test pr' "$OTHER" <"$WORK/r9.body"
    run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes"
    assert_eq "T-R9a 別のコミットのレポートは exit 1" "1" "$(rc)"
    assert_eq "T-R9a 別のコミットのレポートでは add 0 回" "0" "$(add_count)"
    assert_contains "T-R9a レポートの SHA を出す" "$(err)" "$OTHER"
    assert_contains "T-R9a HEAD の SHA を出す" "$(err)" "$H"
    assert_contains "T-R9a 回し直しを促す" "$(err)" "/review を回し直してください"

    # T-R9b: HEAD の行が無い（SHA を書く前の /review のレポート）
    reset_calls
    write_report "$R" '**PR #38**: test pr' '' <"$WORK/r9.body"
    run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes"
    assert_eq "T-R9b HEAD の行が無いレポートは exit 1" "1" "$(rc)"
    assert_eq "T-R9b HEAD の行が無いレポートでは add 0 回" "0" "$(add_count)"
    assert_contains "T-R9b HEAD の SHA が無いと出す" "$(err)" "HEAD の SHA がありません"
    assert_not_contains "T-R9b HEAD の行の欠如で例外を出さない" "$(err)" "Traceback"

    # T-R9c: 旧 T-R9 の入力（mtime を古くする）。SHA が HEAD と一致すれば同じコミットのレビューなので書き込む
    # （旧 T-R9 は exit 1 を期待した。鮮度を mtime ではなく SHA で判定するので、期待値を逆にした）
    reset_calls
    write_report "$R" <"$WORK/r9.body"
    touch -t 202512010000 "$R/tmp/review/unified.md"
    run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes"
    assert_eq "T-R9c SHA が一致すれば mtime が古くても exit 0" "0" "$(rc)"
    assert_eq "T-R9c SHA が一致すれば mtime が古くても add 1 回" "1" "$(add_count)"

    # T-R9d: 短縮形・大文字の SHA は解釈しない（前方一致や大文字小文字の無視に緩めない）
    for bad in "${H:0:7}" "$(printf '%s' "$H" | tr 'a-f' 'A-F')"; do
        reset_calls
        write_report "$R" '**PR #38**: test pr' "$bad" <"$WORK/r9.body"
        run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes"
        assert_eq "T-R9d SHA の形が違えば exit 1（${bad}）" "1" "$(rc)"
        assert_eq "T-R9d SHA の形が違えば add 0 回（${bad}）" "0" "$(add_count)"
        assert_contains "T-R9d SHA の形が違えば SHA が無いと出す（${bad}）" "$(err)" "HEAD の SHA がありません"
    done

    # T-R12（regression）: 参照が複数ある項目・書式のずれた行を黙って落とさない。H_ITEM が参照 1 つで
    # 行末の行にしか合わず、合わない行は skip にも積まれずに読み飛ばされ、件数にも一覧にも出なかった
    R="$(make_repo r12)"; set_pr "$(head_of "$R")"; set_list; reset_calls
    write_report "$R" <<'EOF'
- **H-1. 参照が 2 つ** — `src/foo.ts:L7` / `src/bar.ts:L2`
  2 か所にまたがる。
- **H-2. 後ろに文字がある** — `src/foo.ts:L8`（要確認）
  付く。
- **H-3. em dash でない区切り** - `src/foo.ts:L9`
  区切りが違う。
- **H-4. 行番号の無い参照が先** — `src/foo.tsx (Comp)` / `src/foo.ts:L13`
  行番号のある方に付く。
- **H-5. 行番号が無い** — `src/foo.tsx (Comp)`
  no line に数える。

### C-1．全角ピリオドの見出し
**ファイル**: `src/foo.ts:L10`

### M‐2. U+2010 の見出し
**ファイル**: `src/foo.ts:L11`

### M-3. ファイルの参照が 2 つ
**ファイル**: `src/foo.ts:L12` / `src/baz.ts:L3`

2 つ目も残す。
EOF
    run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes"
    assert_eq "T-R12 正しい項目があれば exit 0" "0" "$(rc)"
    assert_eq "T-R12 add は H-1・H-2・H-4・M-3 の 4 回" "4" "$(add_count)"
    assert_eq "T-R12 参照が 2 つの H は行番号付きの最初の参照に付く" "7" "$(add_opt 1 start-line)"
    assert_contains "T-R12 H の 2 つ目の参照を body に残す" "$(add_opt 1 body)" "関連: src/bar.ts:L2"
    assert_eq "T-R12 参照の後ろに文字がある H も付く" "8" "$(add_opt 2 start-line)"
    assert_not_contains "T-R12 参照の外の文字は body に入れない" "$(add_opt 2 body)" "要確認"
    assert_eq "T-R12 行番号の無い参照が先でも、行番号のある参照に付く" "13" "$(add_opt 3 start-line)"
    assert_contains "T-R12 行番号の無い参照は body に残す" "$(add_opt 3 body)" "関連: src/foo.tsx (Comp)"
    assert_eq "T-R12 ファイルの参照が 2 つの M は最初の参照に付く" "12" "$(add_opt 4 start-line)"
    assert_contains "T-R12 ファイルの 2 つ目の参照を body に残す" "$(add_opt 4 body)" "関連: src/baz.ts:L3"
    assert_contains "T-R12 書式のずれた行を件数に出す" "$(out)" "skipped (unparsed) 3"
    assert_contains "T-R12 行番号が無いものと書式のずれを分けて数える" "$(out)" "skipped (no line) 1, skipped (unparsed) 3,"
    assert_contains "T-R12 全角ピリオドの見出しを出す" "$(out)" "### C-1．"
    assert_contains "T-R12 U+2010 の見出しを出す" "$(out)" "### M‐2."
    assert_contains "T-R12 em dash でない区切りの H を出す" "$(out)" "H-3. em dash でない区切り"
    assert_contains "T-R12 理由を出す" "$(out)" "書式を解釈できない"
    # 正しい項目が 0 件でも、何が消えたかを件数と内訳で出してから止める（「0 件」で先に止まらない）
    reset_calls
    write_report "$R" <<'EOF'
### C-1．全角ピリオドの見出し
**ファイル**: `src/foo.ts:L10`
EOF
    run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes"
    assert_eq "T-R12 書式のずれだけなら exit 1" "1" "$(rc)"
    assert_eq "T-R12 書式のずれだけなら add 0 回" "0" "$(add_count)"
    assert_contains "T-R12 書式のずれだけでも件数を出す" "$(out)" "skipped (unparsed) 1"
    assert_contains "T-R12 書式のずれだけでも内訳を出す" "$(out)" "### C-1．"
    assert_not_contains "T-R12 書式のずれだけでは「0 件」で先に止まらない" "$(err)" "0 件しか"
    assert_contains "T-R12 全件 skip の理由は skipped の行にあると出す" "$(err)" "理由は上の skipped の行"

    # T-R13（regression）: 位置を正規化し、HEAD のファイルで確かめる。行番号 0 は add の失敗で全体を止め、
    # `./` 付きは重複判定の鍵が保存値と合わず再実行のたびに増え、範囲外の行番号は存在しない位置に付いた
    R="$(make_repo r13)"; H="$(head_of "$R")"; set_pr "$H"; set_list; reset_calls
    write_report "$R" <<'EOF'
- **H-1. 行番号 0** — `src/foo.ts:L0`
- **H-2. ./ 付き** — `./src/foo.ts:L42`
- **H-3. HEAD に無い** — `src/nope.ts:L1`
- **H-11. ディレクトリ** — `src:L1`
- **H-4. 範囲外** — `src/foo.ts:L201`
- **H-5. 2^53 超** — `src/foo.ts:L9007199254740993`
- **H-6. 列挙** — `src/foo.ts:L100,L158`
- **H-7. 全角コロン** — `src/foo.ts：L1`
- **H-8. en dash** — `src/foo.ts:L1–3`
- **H-9. 行番号が無い** — `src/foo.ts (Comp)`
- **H-10. 後ろの指摘** — `src/foo.ts:L5`

### C-1. ファイルの全角コロン
**ファイル**: `src/foo.ts：L2`
EOF
    run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes"
    assert_eq "T-R13 正しい項目があれば exit 0" "0" "$(rc)"
    assert_eq "T-R13 add は H-2・H-10 の 2 回（行番号 0 で止まらない）" "2" "$(add_count)"
    assert_eq "T-R13 ./ を外したパスで add する" "src/foo.ts" "$(add_opt 1 file)"
    assert_eq "T-R13 ./ 付きの行" "42" "$(add_opt 1 start-line)"
    assert_eq "T-R13 行番号 0 の後ろの指摘も add する" "5" "$(add_opt 2 start-line)"
    assert_contains "T-R13 行番号 0 の理由" "$(out)" "H-1 src/foo.ts:L0 — 行番号が 1 未満"
    assert_contains "T-R13 HEAD に無いファイルの理由" "$(out)" "H-3 src/nope.ts:L1 — HEAD にファイルが無い"
    assert_contains "T-R13 ディレクトリはファイルとみなさない" "$(out)" "H-11 src:L1 — HEAD にファイルが無い"
    assert_contains "T-R13 範囲外の理由" "$(out)" "H-4 src/foo.ts:L201 — 行がファイルの範囲外"
    assert_contains "T-R13 2^53 超の理由" "$(out)" "H-5 src/foo.ts:L9007199254740993 — 行がファイルの範囲外"
    assert_contains "T-R13 列挙の理由" "$(out)" "H-6 src/foo.ts:L100,L158 — 行番号の書式を解釈できない"
    assert_contains "T-R13 全角コロンの理由" "$(out)" "H-7 src/foo.ts：L1 — 行番号の書式を解釈できない"
    assert_contains "T-R13 en dash の理由" "$(out)" "H-8 src/foo.ts:L1–3 — 行番号の書式を解釈できない"
    assert_contains "T-R13 ファイルの行の全角コロンの理由" "$(out)" "C-1 src/foo.ts：L2 — 行番号の書式を解釈できない"
    assert_contains "T-R13 行番号が無い参照の理由" "$(out)" "H-9 src/foo.ts (Comp) — 行番号が無い"
    # 2 回目: atlas が ./ を外して保存した note が list に出る。正規化した鍵なら重複として飛ばす
    reset_calls
    set_list "$(note src/foo.ts "$H" 42 42 "[H-2] ./ 付き")"
    run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes"
    assert_eq "T-R13 2 回目は ./ 付きの指摘を add しない" "1" "$(add_count)"
    assert_contains "T-R13 2 回目は ./ 付きの指摘を重複に数える" "$(out)" "skipped (duplicate) 1"

    # T-R14: 外部コマンドと実行場所の失敗経路。rc だけだと、検査が消えても別の理由で exit 1 になって通るので、
    # メッセージと Traceback の無さまで見る
    R="$(make_repo r14)"; set_pr "$(head_of "$R")"; set_list; reset_calls
    one_c_report "$R"
    (export FAKE_LIST_RC=3; run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes")
    assert_eq "T-R14 list の失敗は exit 1" "1" "$(rc)"
    assert_eq "T-R14 list の失敗では add 0 回" "0" "$(add_count)"
    assert_contains "T-R14 list の失敗と出す" "$(err)" "atlas-notes list が失敗しました"
    assert_contains "T-R14 list の stderr を転記する" "$(err)" "cannot open store (fake)"
    reset_calls
    printf 'not json\n' >"$WORK/gh.json"
    run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes"
    assert_eq "T-R14 gh の出力が JSON でなければ exit 1" "1" "$(rc)"
    assert_contains "T-R14 gh の出力を読めないと出す" "$(err)" "gh pr view の出力を読めません"
    assert_not_contains "T-R14 gh の出力が JSON でなくても例外を出さない" "$(err)" "Traceback"
    reset_calls
    set_pr "$(head_of "$R")"
    mkdir -p "$WORK/norepo"
    (export GIT_CEILING_DIRECTORIES="$WORK"; run_script "$WORK/norepo" --pr 38 --atlas-notes "$WORK/atlas-notes")
    assert_eq "T-R14 repo の外では exit 1" "1" "$(rc)"
    assert_contains "T-R14 repo の外では repo の中で実行するよう出す" "$(err)" "git の repo の中で実行してください"
    reset_calls
    cp "$R/tmp/review/unified.md" "$WORK/r14-report.md"
    : >"$R/tmp/review/unified.md"
    run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes" --report "$WORK/r14-report.md"
    assert_eq "T-R14 --report の絶対パスを読む" "0" "$(rc)"
    assert_eq "T-R14 --report の絶対パスのレポートを add する" "1" "$(add_count)"

    # T-R15: 失敗の経路でも内訳を出す・--report の相対パスは cwd から・外部コマンドの不在と非 UTF-8・非 ASCII の数字
    R="$(make_repo r15)"; set_pr "$(head_of "$R")"; set_list; reset_calls
    write_report "$R" <<'EOF'
- **H-1. 行番号が無い** — `src/foo.ts (Comp)`
- **H-2. 全角の数字** — `src/foo.ts:L４２`

### C-1. 付く
**ファイル**: `src/foo.ts:L3`
EOF
    (export FAKE_ADD_FAIL_AT=1; run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes")
    assert_eq "T-R15 add の失敗は exit 1" "1" "$(rc)"
    assert_contains "T-R15 add の失敗でも skip の内訳を出す" "$(out)" "skipped: H-1 src/foo.ts (Comp) — 行番号が無い"
    assert_contains "T-R15 全角の数字は行番号として読まない" "$(out)" "H-2 src/foo.ts:L４２ — 行番号の書式を解釈できない"
    reset_calls
    run_script "$R/src" --pr 38 --atlas-notes "$WORK/atlas-notes" --report ../tmp/review/unified.md
    assert_eq "T-R15 --report の相対パスは cwd から解決する" "0" "$(rc)"
    assert_eq "T-R15 --report の相対パスのレポートを add する" "1" "$(add_count)"
    reset_calls
    run_script "$R/src" --pr 38 --atlas-notes "$WORK/atlas-notes"
    assert_eq "T-R15 --report 未指定ならサブディレクトリからでも root の既定を読む" "1" "$(add_count)"
    reset_calls
    local pyabs nogh
    pyabs="$("$PY" -c 'import sys; print(sys.executable)')"
    nogh="$WORK/nogh"; mkdir -p "$nogh"; ln -sf "$(command -v git)" "$nogh/git"
    (cd "$R" && PATH="$nogh" FAKE_DIR="$WORK" "$pyabs" "$TARGET" --pr 38 --atlas-notes "$WORK/atlas-notes") >"$WORK/out" 2>"$WORK/err"
    echo $? >"$WORK/rc"
    assert_eq "T-R15 gh が無ければ exit 1" "1" "$(rc)"
    assert_contains "T-R15 gh が無いと出す" "$(err)" "gh が見つかりません"
    assert_not_contains "T-R15 gh が無くても例外を出さない" "$(err)" "Traceback"
    reset_calls
    printf '\xff\xfe{\n' >"$WORK/gh.json"
    run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes"
    assert_eq "T-R15 gh の出力が UTF-8 でなければ exit 1" "1" "$(rc)"
    assert_contains "T-R15 gh の出力が UTF-8 でなくても読めないと出す" "$(err)" "gh pr view の出力を読めません"
    assert_not_contains "T-R15 gh の出力が UTF-8 でなくても例外を出さない" "$(err)" "Traceback"
    set_pr "$(head_of "$R")"

    # T-R16: add のループ中の Ctrl-C でも、どこまで書いたかを出して 130 で終わる
    # （バックグラウンドのジョブは SIGINT を無視するので、SIG_DFL に戻してから exec する）
    R="$(make_repo r16)"; set_pr "$(head_of "$R")"; set_list; reset_calls
    printf '%s' "$FULL_BODY" | write_report "$R"
    (
        cd "$R" || exit 1
        PATH="$WORK/bin:$PATH" FAKE_DIR="$WORK" FAKE_ADD_SLEEP=3 "$PY" -c \
            'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execv(sys.executable, [sys.executable] + sys.argv[1:])' \
            "$TARGET" --pr 38 --atlas-notes "$WORK/atlas-notes" >"$WORK/out" 2>"$WORK/err" &
        pid=$!
        # 1 回目の add は FAKE_ADD_SLEEP 秒眠るので、待つ上限はそれより十分長くする（遅い環境で add 0 のまま kill しない）
        for _ in $(seq 150); do
            [[ "$(add_count)" -ge 2 ]] && break
            sleep 0.1
        done
        kill -INT "$pid"
        wait "$pid"
        echo $? >"$WORK/rc"
    )
    assert_eq "T-R16 Ctrl-C は exit 130" "130" "$(rc)"
    assert_contains "T-R16 Ctrl-C でも件数を出す" "$(out)" "added 1"
    assert_contains "T-R16 Ctrl-C で中断したと出す" "$(err)" "中断しました"
    assert_not_contains "T-R16 Ctrl-C で例外を出さない" "$(err)" "Traceback"

    # T-R11: repo のパスに空白があっても HEAD を正しく読む（空白で分けると HEAD のずれと誤って診断する）
    R="$(make_repo "r 11")"; set_pr "$(head_of "$R")"; set_list; reset_calls
    one_c_report "$R"
    run_script "$R" --pr 38 --atlas-notes "$WORK/atlas-notes"
    assert_eq "T-R11 パスに空白のある repo でも exit 0" "0" "$(rc)"
    assert_eq "T-R11 パスに空白のある repo でも add 1 回" "1" "$(add_count)"

    # T-R10: --atlas-notes 無しは XDG_DATA_HOME と NVIM_APPNAME で探し、NVIM_APPNAME を引き継ぐ
    R="$(make_repo r10)"; set_pr "$(head_of "$R")"; set_list; reset_calls
    one_c_report "$R"
    local X="$WORK/xdg"
    mkdir -p "$X/nvim-pr/lazy/atlas.nvim/bin" "$X/nvim/lazy/atlas.nvim/bin"
    cp "$WORK/atlas-notes" "$X/nvim-pr/lazy/atlas.nvim/bin/atlas-notes"
    cp "$WORK/atlas-notes" "$X/nvim/lazy/atlas.nvim/bin/atlas-notes"
    (export XDG_DATA_HOME="$X" NVIM_APPNAME=nvim-pr; run_script "$R" --pr 38)
    assert_eq "T-R10 探した atlas-notes で追加できる" "1" "$(add_count)"
    assert_eq "T-R10 NVIM_APPNAME の下の atlas-notes を使う" "$X/nvim-pr/lazy/atlas.nvim/bin/atlas-notes" \
        "$("$PY" -c 'import json,sys; print([json.loads(l)["self"] for l in open(sys.argv[1])][-1])' "$WORK/notes.calls")"
    assert_eq "T-R10 NVIM_APPNAME を atlas-notes に引き継ぐ" "nvim-pr" \
        "$("$PY" -c 'import json,sys; print([json.loads(l)["appname"] for l in open(sys.argv[1])][-1])' "$WORK/notes.calls")"
    reset_calls
    (export XDG_DATA_HOME="$X"; unset NVIM_APPNAME; run_script "$R" --pr 38)
    assert_eq "T-R10 NVIM_APPNAME が無ければ nvim の下を使う" "$X/nvim/lazy/atlas.nvim/bin/atlas-notes" \
        "$("$PY" -c 'import json,sys; print([json.loads(l)["self"] for l in open(sys.argv[1])][-1])' "$WORK/notes.calls" 2>/dev/null)"
}

# python3 と /usr/bin/python3 が別物なら両方で全件を回す（3.9 で動くことの検証）
PYS=(python3)
if [[ -x /usr/bin/python3 ]] && \
    [[ "$(/usr/bin/python3 -c 'import sys; print(sys.version)')" != "$(python3 -c 'import sys; print(sys.version)')" ]]; then
    PYS+=(/usr/bin/python3)
fi

if [[ "${#PYS[@]}" -eq 1 ]]; then
    echo "警告: /usr/bin/python3 が無いか python3 と同じ版なので、/usr/bin/python3 での 2 本目の実行は行いません（3.9 で動くことを確かめていません）" >&2
fi

if [[ ! -f "$TARGET" ]]; then
    echo "test-review-to-atlas-notes.sh: 検査対象が見つからない: $TARGET" >&2
fi

run_no=0
for PY in "${PYS[@]}"; do
    run_no=$((run_no + 1))
    WORK="$BASE/run-$run_no"
    mkdir -p "$WORK"
    LABEL="[$("$PY" -c 'import sys; print("py%d.%d" % sys.version_info[:2])')] "
    echo "== ${PY}（$("$PY" --version 2>&1)）=="
    run_tests
done

echo
echo "${pass_count} passed / ${fail_count} failed（python: ${PYS[*]}）"
[[ "$fail_count" -eq 0 ]] || exit 1
