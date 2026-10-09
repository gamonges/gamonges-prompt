#!/bin/bash
#
# verify-skills.sh
# ----------------
# shared/skills/ と ~/.claude/skills/ の整合性を機械的に検証する。
#
# 検証項目:
# 1. SKILL.md ファイル数の一致 (リポ vs インストール先)
# 2. 各 SKILL.md の frontmatter に name フィールドが存在すること
#    (b) 既定の入力が ./tmp/context.md の skill が、入口の正典 brief/reference/entry.md を参照していること
# 3. 各 ~/.claude/skills/<name> が本リポを指す symlink であること
# 4. shared/scripts/ と ~/.claude/scripts/ の同期状態 (実体コピー方式のため。warn 止まり)
# 5. skill listing の description 総文字数 (budget 監視。warn 止まり)
# 6. settings.json に登録された hook の実体が存在すること
# 7. (1) 同期状態を見る実装の対称性（逆走査・glob 対）と、複製した判定の一致（ask を返す hook 4 本の
#       decide_ask_or_deny は本体を多数決で比べ、setup.sh と複製した「自分のリンク」・マーカーの並びの判定は
#       本体を比べる。「自前 hook」の判定は基準の文字列が両方にあるかを見る）
#    (2) ガードレール系 hook（tmp-commit・contract-link・破壊的 git の 3 本）が grep -q へ直接パイプしていないこと
#       (SIGPIPE + pipefail の fail-open)
# 8. Codex の skills (~/.agents/skills) が今のチェックアウトを指していること (~/.codex があるときのみ)
# 9. disable-model-invocation: true の skill と agents/openai.yaml (Codex の暗黙起動の抑止) の一致
# 10. Codex の agents (TOML) が shared/agents から生成したものと同期していること (~/.codex があるときのみ)
# 11. ~/.codex/AGENTS.md の 2 ブロックのマーカーの並びが正しく、中身が最新で、repo 直下と合わせて 32 KiB に収まること (同上)
# 12. ~/.codex/hooks.json が JSON のオブジェクトで、自前 hook（settings.json・hooks.json のどちらかで 0 本なら warn）が
#     各イベントの先頭にあり、config.toml に信頼キーがあること (同上)
# 13. Codex の版が、前提（信頼ハッシュ・apply_patch の文法）を確かめた版（codex/verified-codex-version）と同じであること (同上)
#
# 依存: check 5・10・12(b) が python3 を、check 12 が jq を使う。利用できない場合はその check をスキップして続行する。
#
# 終了コード: fail が 1 件でもあれば 1、それ以外は 0 (warn があっても 0)
#
# 使い方:
#   ./shared/scripts/verify-skills.sh                        構造検証のみ
#   ./shared/scripts/verify-skills.sh --with-behavior-tests   挙動テストも実行する
#
# 挙動テスト (tests/test-guardrails.sh・tests/test-setup-codex.sh) を既定で走らせないのは、fixture 生成に数十秒かかり
# 構造検証の即応性を損なうため。ただし fail-open は挙動テストしか捉えられないので、
# shared/scripts/ を編集したときはフラグ付きで実行する。
set -euo pipefail

WITH_BEHAVIOR_TESTS=0
for arg in "$@"; do
    case "$arg" in
        --with-behavior-tests) WITH_BEHAVIOR_TESTS=1 ;;
        -h|--help)
            sed -n '/^# 使い方:/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "verify-skills.sh: 不明な引数: $arg" >&2
            echo "  使える引数: --with-behavior-tests / --help" >&2
            exit 2
            ;;
    esac
done

# 自スクリプトの所在から派生させる。$0 と ${BASH_SOURCE[0]} を混在させず 1 箇所で算出する。
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# 共通資産（skills / agents / scripts）は shared/、settings.json は Claude Code 固有なので claude/
REPO_SHARED="${REPO_ROOT}/shared"
REPO_CLAUDE="${REPO_ROOT}/claude"
REPO_SKILLS="${REPO_SHARED}/skills"
INSTALLED_SKILLS="$HOME/.claude/skills"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

fail_count=0
warn_count=0

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
# fail() は即 exit しない。checks 1-3 が落ちる状況 (チェックアウトの切替・install 忘れ) こそ
# scripts の同期ズレ (check 4) を見たい場面であり、fail-fast にすると最も必要なときに到達しない。
# 合否は末尾で fail_count を見て決める。
fail() { echo -e "${RED}[FAIL]${NC} $1"; fail_count=$((fail_count + 1)); }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; warn_count=$((warn_count + 1)); }

# 1. SKILL.md count (本リポを指す symlink の数で計測、_ プレフィックスは雛形扱いで対象外)
expected=0
installed=0
for skill_dir in "$REPO_SKILLS"/*/; do
    name=$(basename "$skill_dir")
    [[ "$name" == _* ]] && continue
    expected=$((expected + 1))
    target="$INSTALLED_SKILLS/$name"
    if [ -L "$target" ]; then
        link_target=$(readlink "$target")
        if [ "$link_target" = "${skill_dir%/}" ] || [ "$link_target" = "$skill_dir" ]; then
            installed=$((installed + 1))
        fi
    fi
done

if [ "$expected" = "$installed" ]; then
    pass "SKILL.md count matches: $expected (repo) == $installed (installed)"
else
    fail "SKILL.md count mismatch: $expected (repo) != $installed (installed)"
fi

# 2. frontmatter "name" field の存在 (_ プレフィックスも対象) と、ディレクトリ名との一致
#    一致検証から _ プレフィックスを除くのは、_template の name が `<skill-name>` という
#    プレースホルダで、ディレクトリ名と一致させる意味がないため
missing=()
mismatch=()
for skill in "$REPO_SKILLS"/*/SKILL.md; do
    dir=$(basename "$(dirname "$skill")")
    nm=$(head -10 "$skill" | sed -n 's/^name:[[:space:]]*//p' | head -1)
    if [ -z "$nm" ]; then
        missing+=("$skill")
        continue
    fi
    [[ "$dir" == _* ]] && continue
    # 不一致でも起動はする (起動名はディレクトリ名) が、skillOverrides はディレクトリ名を
    # キーにするため、name を頼りに設定を書くと黙って効かない事故になる
    if [ "$nm" != "$dir" ]; then
        mismatch+=("$dir != $nm")
    fi
done

if [ ${#missing[@]} -eq 0 ]; then
    pass "All SKILL.md have 'name:' field"
else
    for m in "${missing[@]}"; do
        echo "  missing name in: $m"
    done
    fail "${#missing[@]} SKILL.md files missing 'name:' field"
fi

if [ ${#mismatch[@]} -eq 0 ]; then
    pass "All skill directory names match frontmatter 'name'"
else
    for m in "${mismatch[@]}"; do
        echo "  mismatch: $m"
    done
    fail "${#mismatch[@]} skills have directory name != frontmatter 'name'"
fi

# 2(b). 既定の入力が ./tmp/context.md の skill（文言「省略時は `./tmp/context.md`」で見つける）は、入口の正典
# brief/reference/entry.md を参照すること。参照しないと、質問を文章で渡す・自然文で頼む入口で即停止するか、
# 正典の無い独自の解釈で動く。skill 名で固定しないのは、同じ形の skill を足したときに漏れないため
echo ""
echo -e "${BLUE}== check 2(b): 入口の正典の参照（既定の入力が ./tmp/context.md の skill）==${NC}"
entry_doc="${REPO_SKILLS}/brief/reference/entry.md"
entry_targets=()
entry_missing=()
for skill_md in "$REPO_SKILLS"/*/SKILL.md; do
    dir=$(basename "$(dirname "$skill_md")")
    [[ "$dir" == _* ]] && continue
    grep -qF '省略時は `./tmp/context.md`' "$skill_md" || continue
    entry_targets+=("$dir")
    grep -qF '../brief/reference/entry.md' "$skill_md" || entry_missing+=("$dir")
done
if [ ! -f "$entry_doc" ]; then
    fail "入口の正典 shared/skills/brief/reference/entry.md がありません（${#entry_targets[@]} 件の skill が参照する先）"
elif [ ${#entry_missing[@]} -gt 0 ]; then
    fail "入口の正典（../brief/reference/entry.md）を参照していない skill: ${entry_missing[*]}"
else
    pass "既定の入力が ./tmp/context.md の skill ${#entry_targets[@]} 件（${entry_targets[*]}）が、入口の正典を参照しています"
fi

# 3. symlink integrity (_ プレフィックスは雛形扱いで対象外)
# 見出しは 2(b) の節の終わりの目印も兼ねる（テストは見出しから次の見出しまでを 1 つの check として切り出す）
echo ""
echo -e "${BLUE}== check 3: ~/.claude/skills のリンク ==${NC}"
broken=()
for skill_dir in "$REPO_SKILLS"/*/; do
    name=$(basename "$skill_dir")
    [[ "$name" == _* ]] && continue
    target="$INSTALLED_SKILLS/$name"

    if [ ! -L "$target" ]; then
        broken+=("$name (not a symlink)")
        continue
    fi

    link_target=$(readlink "$target")
    expected_target="${skill_dir%/}"
    if [ "$link_target" != "$expected_target" ] && [ "$link_target" != "$skill_dir" ]; then
        broken+=("$name (points to: $link_target)")
    fi
done

if [ ${#broken[@]} -eq 0 ]; then
    pass "All ${expected} skills are correctly symlinked to repo"
else
    for b in "${broken[@]}"; do
        echo "  broken: $b"
    done
    fail "${#broken[@]} skill symlinks have issues"
fi

# 4. scripts の同期状態 (実体コピー方式。ズレは warn 止まりで fail にしない)
REPO_SCRIPTS="${REPO_SHARED}/scripts"
INSTALLED_SCRIPTS="$HOME/.claude/scripts"
stale=()
for script in "$REPO_SCRIPTS"/*.sh "$REPO_SCRIPTS"/*.py; do
    [ -f "$script" ] || continue
    name=$(basename "$script")
    # check 1 のカウンタ $installed と役割が違うので別名にする
    installed_path="$INSTALLED_SCRIPTS/$name"

    if [ -L "$installed_path" ]; then
        stale+=("$name (旧形式の symlink)")
    elif [ ! -f "$installed_path" ]; then
        stale+=("$name (未インストール)")
    elif ! cmp -s "$script" "$installed_path"; then
        stale+=("$name (repo と差分あり)")
    elif [ ! -x "$installed_path" ]; then
        # cmp は内容しか見ずモードを比較しない。実行ビットが落ちた hook は exit 126 になり、
        # exit 127 と同じく non-blocking なのでガードレールが黙って開く
        stale+=("$name (実行ビットなし — 実行すると exit 126)")
    fi
done

# 逆方向の走査。repo 起点のループだけでは「repo から削除されたのに残っているファイル」が
# どこからも見えず、dangling symlink が exit 127 でガードレールを開ける状態を検出できない
for installed_path in "$INSTALLED_SCRIPTS"/*.sh "$INSTALLED_SCRIPTS"/*.py; do
    [ -e "$installed_path" ] || [ -L "$installed_path" ] || continue
    name=$(basename "$installed_path")
    [ -f "$REPO_SCRIPTS/$name" ] && continue
    if [ -L "$installed_path" ] && [ ! -e "$installed_path" ]; then
        stale+=("$name (repo に存在しない orphan / dangling — 実行すると exit 127)")
    else
        stale+=("$name (repo に存在しない orphan)")
    fi
done

# install 時のバックアップ残存。*.sh.backup.<ts> は *.sh glob に当たらないため
# 正走査・逆走査のどちらにも映らず、静かに蓄積する
for backup in "$INSTALLED_SCRIPTS"/*.backup.*; do
    [ -e "$backup" ] || continue
    stale+=("$(basename "$backup") (install 時のバックアップが残存 — 内容を確認して削除する)")
done

if [ ${#stale[@]} -eq 0 ]; then
    pass "All scripts are in sync with repo"
else
    for s in "${stale[@]}"; do
        echo "  stale: $s"
    done
    warn "${#stale[@]} scripts out of sync — run ./setup.sh install（orphan は --prune-scripts）"
fi

# install 出自の照合。実体コピーでは symlink と違いリンク先から由来が読めないため、
# install 時に記録した出自と現在のチェックアウトを突き合わせる。
# 判定を「main 以外なら警告」にしないのは、worktree + feature ブランチが本リポジトリの
# 標準運用であり、通常作業で常時点灯する警告は無視されるようになるため
if [ -f "$INSTALLED_SCRIPTS/.installed-from" ]; then
    IFS=$'\t' read -r from_dir from_branch from_sha < "$INSTALLED_SCRIPTS/.installed-from" || true
    if [ -z "${from_dir:-}" ]; then
        # 空ファイルだと全フィールドが空になり、素通りさせると「出自を照合した」ことになってしまう。
        # 末尾改行の欠落は read が値を返すので実害がなく、ここでは区別しない
        warn ".installed-from が空です: $INSTALLED_SCRIPTS/.installed-from（./setup.sh install で再生成）"
    elif [ ! -d "$from_dir" ]; then
        # install 元の worktree が削除されると、skills の symlink も同時に dangling になる
        warn ".installed-from が指すチェックアウトがありません: ${from_dir}（install 元が削除された可能性）"
    elif [ "$from_dir" != "$REPO_ROOT" ]; then
        warn "scripts は別のチェックアウトから install されています: $from_dir (${from_branch:-?} ${from_sha:-?})"
    fi
elif ls "$INSTALLED_SCRIPTS"/*.sh >/dev/null 2>&1; then
    # scripts はあるのに出自が無い＝旧版からの移行途中。初回 install 前（scripts 0 件）と
    # 区別しないと、provenance 不明という検知したい状態が無警告で通る
    warn "scripts の出自が不明です（.installed-from が無い）。メインチェックアウトで ./setup.sh install を実行してください"
fi

# 5. skill listing の description 総文字数 (budget 監視。閾値はモデル依存のため fail にしない)
#    disable-model-invocation: true の skill は listing に載らないため除外する
#    python3 の不在や SKILL.md の読み込み失敗でスクリプト全体を落とさないよう if で包む。
#    set -e 下では代入形式の command substitution が非ゼロ終了すると即座に全体が終了するため。
if listing_report=$(python3 - "$REPO_SKILLS" "$REPO_CLAUDE/settings.json" <<'PY'
import glob, json, os, re, sys
root = sys.argv[1]

# settings.json の skillOverrides も listing 対象の判定に含める。frontmatter だけを見ると
# name-only / user-invocable-only / off にした skill が「まだ listing に載っている」と
# 数えられ、解消しようのない warn が常時点灯して検出力を失う。
# 読み取り専用・失敗時は無視することで結合を最小に留める。
# パスは引数で受け取る。skills/ の 1 つ上を os.pardir で推測すると、skills/ の置き場所を
# 変えたとき（claude/ → shared/）に存在しないファイルを読み、例外を握りつぶして overrides が
# 空になる（listing の件数が静かに狂い、気づけない）
overrides = {}
try:
    with open(sys.argv[2], encoding="utf-8") as fp:
        overrides = json.load(fp).get("skillOverrides", {}) or {}
except (OSError, ValueError):
    pass
HIDDEN_STATES = ("name-only", "user-invocable-only", "off")


def clean(raw):
    """block scalar の指示子・改行・インデント・引用符を除いた description 本体を返す。
    これらを含めて数えると 120 字の境界付近で偽陽性になる"""
    d = raw.strip()
    if d and d[0] in "|>":
        d = d[1:].lstrip("+-0123456789")
    d = " ".join(l.strip() for l in d.splitlines() if l.strip())
    return d.strip('"').strip("'")


listed = hidden_fm = hidden_ov = chars = 0
over = []
seen = set()
for f in sorted(glob.glob(os.path.join(root, "*", "SKILL.md"))):
    name = os.path.basename(os.path.dirname(f))
    if name.startswith("_"):
        continue
    seen.add(name)
    # 不正な UTF-8 を含む SKILL.md 1 件で検証全体が止まらないよう置換して読む
    text = open(f, encoding="utf-8", errors="replace").read()
    m = re.search(r"^---\n(.*?)\n---", text, re.S)
    if not m:
        continue
    fm = m.group(1)
    d = re.search(r"^description:\s*(.*(?:\n[ \t]+.*)*)", fm, re.M)
    desc = clean(d.group(1)) if d else ""
    if re.search(r"^disable-model-invocation:\s*true", fm, re.M):
        hidden_fm += 1
        continue
    if overrides.get(name) in HIDDEN_STATES:
        hidden_ov += 1
        continue
    listed += 1
    chars += len(desc)
    if len(desc) > 120:
        over.append(f"{name}({len(desc)})")
# skillOverrides のキーが実在する repo skill かを照合する。ディレクトリ名がキーなので、
# 名前を間違えても plugin 由来 skill を指定しても、設定は黙って無効になるだけで気づけない
unknown = sorted(set(overrides) - seen)
print(f"{listed}\t{hidden_fm}\t{hidden_ov}\t{chars}\t{' '.join(over)}\t{' '.join(unknown)}")
PY
); then
    listed_n=$(echo "$listing_report" | cut -f1)
    hidden_fm=$(echo "$listing_report" | cut -f2)
    hidden_ov=$(echo "$listing_report" | cut -f3)
    chars_n=$(echo "$listing_report" | cut -f4)
    over_list=$(echo "$listing_report" | cut -f5)
    unknown_ov=$(echo "$listing_report" | cut -f6)

    # [INFO] は pass() と別色にする。GREEN だと「5 番目のチェックが通った」と読めてしまう
    # 「listing」と呼ぶと PR 本文の plugin 込みの値と混同されるため、何を数えたかを明示する。
    # ここが数えているのは repo skill の description だけで、listing budget の実測ではない
    echo -e "${BLUE}[INFO]${NC} repo skill の description 総和: ${listed_n} 件 / ${chars_n} 文字 (対象外: frontmatter ${hidden_fm} 件 / skillOverrides ${hidden_ov} 件)"
    echo -e "        plugin を含む実際の listing budget は /context で確認する（本チェックでは測れない）"
    if [ -n "$over_list" ]; then
        warn "description が 120 字を超える skill: ${over_list}"
    fi
    if [ -n "$unknown_ov" ]; then
        # repo skill に無いキーには 2 種類ある: タイポで黙って無効になっているものと、
        # 組み込み skill を意図的に隠しているもの。後者は正当な運用なので warn にしない
        # （実測: find-skills は組み込み skill で、user-invocable-only が効いて listing から
        # 消えていた。キーを外すと listing に復活する）。
        # 両者を機械的に区別する手段が無いため、判断材料として INFO で出すに留める
        echo -e "${BLUE}[INFO]${NC} skillOverrides に repo skill 以外のキー: ${unknown_ov}"
        echo -e "        組み込み / plugin skill を隠している場合は正当。心当たりが無ければキー名のタイポを疑う"
    fi
else
    warn "check 5 (listing budget) をスキップしました（python3 が利用できないか SKILL.md の読み込みに失敗）"
fi

# 6. settings.json に登録された hook の実体があるか
#    hook 登録は settings.json の symlink 経由で即時反映されるが、scripts は実体コピーのため
#    install まで配置されない。この非対称は exit 127 (non-blocking) として現れ、
#    ガードレールが「止まる」のではなく「開く」。2 種類の失敗は性質が違うので分ける:
#      repo 側の欠落 = 登録したがファイルを作り忘れた。install しても直らないので fail
#      install 先の欠落 = install 待ちの過渡状態。./setup.sh install で解消するので warn
if hook_cmds=$(python3 - "$REPO_CLAUDE/settings.json" <<'PY'
import json, os, shlex, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fp:
        cfg = json.load(fp)
except (OSError, ValueError):
    sys.exit(1)
out = []
for matchers in (cfg.get("hooks") or {}).values():
    for matcher in matchers or []:
        for hook in matcher.get("hooks") or []:
            raw = hook.get("command") or ""
            if not raw:
                continue
            # 引数付きコマンドを想定して shlex で分割する。単純な split() はスペースを含む
            # パスを途中で切り、存在しない別のパスを検査して「実行可能」と誤判定しうる
            try:
                parts = shlex.split(raw)
            except ValueError:
                continue
            if parts:
                out.append(os.path.expanduser(parts[0]))
print("\n".join(out))
PY
); then
    while IFS= read -r cmd; do
        [ -n "$cmd" ] || continue
        # repo が配布するスクリプトを指す hook だけを検査する。npx や jq のような外部コマンドは
        # repo に無いのが当然で、対象に含めると hook を 1 つ足すたびに誤 fail する
        case "$cmd" in
            "$HOME/.claude/scripts/"*) ;;
            *) continue ;;
        esac
        hook_name=$(basename "$cmd")
        if [ ! -f "$REPO_SCRIPTS/$hook_name" ]; then
            fail "登録済み hook が repo に存在しません: $hook_name (settings.json に登録済み / shared/scripts/ に無い)"
        elif [ ! -x "$cmd" ]; then
            warn "登録済み hook が未配置または実行不可: $cmd (./setup.sh install が必要)"
        fi
    done <<< "$hook_cmds"
else
    warn "check 6 (hook の実体) をスキップしました（python3 が利用できないか settings.json の解析に失敗）"
fi

# check 7(1): 同期状態を見る 3 実装が逆走査 (orphan 検出) を持っているか
#    repo 起点のループだけでは「repo から削除されたのに残っているファイル」が見えない。
#    3 実装のどれかが欠けると「どの経路で見たかによって検出結果が変わる」非対称になり、
#    自動で走る hook が最も検出力が低いという最悪の配分が起きる。
#    setup.sh は逆走査を持つ install_scripts と持たない show_status が同居するため、
#    ファイル全体ではなく関数本体を切り出して検査する。
#    文字列の有無しか見ない粗い網であり、ロジックの同一性までは保証しない
check_reverse_scan() {  # $1=表示名, $2=検査対象のテキスト
    printf '%s' "$2" | grep -q 'orphan' \
        || warn "$1 に orphan 検出がありません（同期状態を見る 3 実装の非対称）"
}
echo -e "${BLUE}== check 7(1): 同期状態を見る実装・ask を返す hook・自分のリンクの対称性 ==${NC}"
sym_warn_before=$warn_count
check_reverse_scan "hook-check-scripts-sync.sh" "$(cat "$REPO_SHARED/scripts/hook-check-scripts-sync.sh")"
check_reverse_scan "verify-skills.sh (check 4)" "$(cat "$REPO_SHARED/scripts/verify-skills.sh")"
check_reverse_scan "setup.sh:show_status()"     "$(sed -n '/^show_status()/,/^}/p' "$REPO_ROOT/setup.sh")"

# scripts を走査する箇所は *.sh と *.py の glob を対で持つ。片方を書き忘れると
# 「.py ファイルだけ処理されない」という静かな取りこぼしになり、出力からは気づけない
check_glob_pair() {  # $1=表示名, $2=検査対象のテキスト
    printf '%s' "$2" | grep -q '\*\.py' \
        || warn "$1 に *.py の走査がありません（*.sh との glob 対の揃え忘れ）"
}
check_glob_pair "hook-check-scripts-sync.sh" "$(cat "$REPO_SHARED/scripts/hook-check-scripts-sync.sh")"
check_glob_pair "verify-skills.sh (check 4)" "$(cat "$REPO_SHARED/scripts/verify-skills.sh")"
check_glob_pair "setup.sh:install_scripts()" "$(sed -n '/^install_scripts()/,/^}/p' "$REPO_ROOT/setup.sh")"
check_glob_pair "setup.sh:show_status()"     "$(sed -n '/^show_status()/,/^}/p' "$REPO_ROOT/setup.sh")"

# 複製した関数の本体を取り出す。比べる関数は repo の慣例どおり、行頭の `name() {` の形でトップレベルに定義する
# （`name(){`・`function name`・字下げした定義は拾えない）
fn_body() {  # $1=関数名, $2=ファイル → 本体（定義が無ければ空）
    awk -v head="$1() {" 'index($0, head) == 1 { on = 1 } on { print } on && /^}/ { exit }' "$2"
}
fn_def_count() {  # $1=関数名, $2=ファイル → 定義の数
    local n
    n=$(grep -c "^$1() {" "$2" || true)
    echo "${n:-0}"
}

# Codex は permissionDecision: "ask"（確認プロンプト）に未対応で、未対応の値は hook の失敗として扱われ、
# 操作が続行する（= ガードが黙って開く）。ask を返す hook は decide_ask_or_deny を通し、Codex では deny に
# 変える。共通ファイルを source しない（source の失敗は exit 2 以外になり、ガードが開く）ので、同じ関数を
# 各 hook に複製している。複製の欠落・本体の食い違い・関数を通さない ask の直書きは、その hook だけを Codex で
# 素通しにする。本体は多数決で比べる（先頭の 1 本を基準にすると、先頭が壊れたときに健全な 3 本を名指しする）
da_votes=""
for hook_name in hook-confirm-destructive-git.sh hook-block-local-contract-link.sh hook-block-tmp-commit.sh hook-lint-skill-frontmatter.sh; do
    hook_path="${REPO_SHARED}/scripts/${hook_name}"
    if [ ! -f "$hook_path" ]; then
        warn "${hook_name} がありません（ask を返す hook の一覧が古い）"
        continue
    fi
    da_n=$(fn_def_count decide_ask_or_deny "$hook_path")
    if [ "$da_n" -eq 0 ]; then
        warn "${hook_name} に decide_ask_or_deny() がありません（Codex では ask が確認にならず、この hook のガードが黙って開く）"
        continue
    elif [ "$da_n" -gt 1 ]; then
        # 実行時は後勝ちなので、先頭の定義を比べても意味が無い。票から外す
        warn "${hook_name} に decide_ask_or_deny() の定義が 2 つ以上あります（実行時は後の定義が使われる）"
        continue
    fi
    da_votes="${da_votes}$(fn_body decide_ask_or_deny "$hook_path" | cksum | tr ' ' '-') ${hook_name}"$'\n'
done
da_n=$(printf '%s' "$da_votes" | grep -c . || true)
if [ "$da_n" -ge 3 ]; then
    da_top=$(printf '%s' "$da_votes" | awk '{ print $1 }' | sort | uniq -c | sort -rn | sed -n 1p)
    if [ "$(echo "$da_top" | awk '{ print $1 }')" -ge 3 ]; then
        da_major=$(echo "$da_top" | awk '{ print $2 }')
        while read -r da_sum da_hook; do
            [ -n "$da_sum" ] || continue
            [ "$da_sum" = "$da_major" ] && continue
            warn "${da_hook} の decide_ask_or_deny() の本体が他の 3 本と違う（複製の片側だけを直した。Codex での判定がこの hook だけ変わる）"
        done <<<"$da_votes"
    else
        warn "decide_ask_or_deny() の複製が一致しません（多数派が無い。全 4 本を見比べてください）"
    fi
elif [ "$da_n" -eq 2 ]; then
    if [ "$(printf '%s' "$da_votes" | awk '{ print $1 }' | sort -u | grep -c . || true)" -ne 1 ]; then
        warn "decide_ask_or_deny() の複製が一致しません（残る 2 本の本体が違う）"
    fi
fi
# 直書きの ask は、一覧にある hook に限らず全 hook を見る（5 本目が足されても検知できるように）。
# 二重引用符の中のエスケープ（\"ask\"）も拾う。コメント行は除く（この仕組みを説明するコメントに "ask" の表記が入るため）
for hook_path in "$REPO_SHARED"/scripts/hook-*.sh; do
    [ -f "$hook_path" ] || continue
    hits=$(grep -v '^[[:space:]]*#' "$hook_path" | grep -cE 'permissionDecision\\?"?[[:space:]]*:[[:space:]]*\\?"ask' || true)
    if [ "${hits:-0}" -gt 0 ]; then
        warn "$(basename "$hook_path") に decide_ask_or_deny() を通らない ask の直書きが ${hits} 件あります（Codex では確認にならず、ガードが黙って開く）"
    fi
done

# setup.sh と本ファイルに複製した判定関数は、互いを source しないので本体を比べる。片方だけ直すと、install が
# 張り替えるリンクを verify が他者のものと数える・install が書き込まない並びを verify が案内する、等の食い違いになる
check_dup_pair() {  # $1=関数名, $2=食い違いの説明
    local n_setup n_verify
    n_setup=$(fn_def_count "$1" "$REPO_ROOT/setup.sh")
    n_verify=$(fn_def_count "$1" "${BASH_SOURCE[0]}")
    if [ "$n_setup" -ne 1 ] || [ "$n_verify" -ne 1 ]; then
        # 空どうしの一致を PASS にしない
        warn "$1 の定義が setup.sh に ${n_setup} 個・verify-skills.sh に ${n_verify} 個あります（1 つずつ必要。無いか 2 つ以上ある）"
    elif [ "$(fn_body "$1" "$REPO_ROOT/setup.sh")" != "$(fn_body "$1" "${BASH_SOURCE[0]}")" ]; then
        warn "$1 の本体が setup.sh と verify-skills.sh で一致しません（$2）"
    fi
}
check_dup_pair is_own_skill_link "「自分のリンク」の判定パターン。片方だけ直すと install と check 8 の判定が食い違う"
check_dup_pair own_git_common "「自分のリンク」の判定に使う git の共通ディレクトリ"
check_dup_pair marker_shape "マーカーの並びの判定。片方だけ直すと install と check 11 の判定が食い違う"
# 「自前の hook」の判定（command が /.claude/scripts/ を含む）も、setup.sh と check 12 で同じ基準を使う
for self_file in "$REPO_ROOT/setup.sh" "${BASH_SOURCE[0]}"; do
    if ! grep -qF 'contains("/.claude/scripts/")' "$self_file"; then
        warn "$(basename "$self_file") に自前 hook の判定 contains(\"/.claude/scripts/\") がありません（setup.sh と check 12 は同じ基準で自前の hook を数える）"
    fi
done

if [ "$warn_count" -eq "$sym_warn_before" ]; then
    pass "対称性: 逆走査・glob 対・ask を返す 4 本の decide_ask_or_deny・自分のリンク・マーカーの並び・自前 hook の判定は揃っています（本体が一致）"
fi


# --- check 7(2): ガードレール系 hook の grep -q パイプ ---
# grep -q は最初のマッチで終了するため、書き手 (git / echo) がまだ書いている途中なら
# SIGPIPE で死んで 141 を返し、set -o pipefail がパイプライン全体を 141 にする。
# マッチしているのに if が偽になり、ガードが黙って開く (実測: 入力が 64 KB を超えた時点)。
#
# 対象を 3 本に絞るのは、repo 全体では 31 箇所あり全件を warn にするとノイズになるため。
# この 3 本は matches() ヘルパーへ移行済みで該当 0 件なので、増えたときだけ警告が出る。
# 残る hook は matches() 化してから対象に加える。
#
# コメント行は除く。matches() の由来を説明するコメントに「printf | grep -q では塞がらない」
# という記述が入るため、除かないと原理を説明した行そのものが warn になる。
echo -e "${BLUE}== check 7(2): ガードレール hook の grep -q パイプ ==${NC}"
grep_q_guarded=0
for hook_name in hook-block-local-contract-link.sh hook-block-tmp-commit.sh hook-confirm-destructive-git.sh; do
    hook_path="${REPO_SHARED}/scripts/${hook_name}"
    [ -f "$hook_path" ] || continue
    hits=$(grep -v '^[[:space:]]*#' "$hook_path" | grep -cE '\|[[:space:]]*grep -[a-zA-Z]*q' || true)
    if [ "${hits:-0}" -gt 0 ]; then
        warn "$hook_name に grep -q へのパイプが ${hits} 件ある（SIGPIPE + pipefail で fail-open する。matches() を使う）"
        grep_q_guarded=$((grep_q_guarded + hits))
    fi
done
if [ "$grep_q_guarded" -eq 0 ]; then
    pass "ガードレール hook に grep -q への直接パイプはありません"
fi

# --- check 8: Codex の skills（~/.agents/skills）---
# Codex は ~/.claude/skills を読まず、~/.agents/skills を読む。そこは skills CLI や他のツールも書き込む
# 共有の場所で、同名の他者の実体・リンクが既にあることがある（実機では review がそう）。
#   - 自分のリンクだが今のチェックアウトを指していない（別 worktree・切れたリンク）→ fail
#     install すれば張り替わる状態で、check 3（Claude 側）と同じ扱い
#   - 同名の実体・自分のリンクでない symlink → warn。install が触らず skip した衝突で、fail にすると
#     実機の review で常に fail して他の fail が埋もれる
#   - 未配置 → warn（install 待ち）
# 「自分のリンク」の判定は setup.sh の is_own_skill_link・own_git_common と同じ本体（互いを source しないので
# 複製し、7(1) の対称性 check が一致を確かめる）。実在するリンク先は git の共通ディレクトリで本 repo か確かめる
own_git_common() {  # $1=ディレクトリ → git の共通ディレクトリ（絶対パス。git でなければ空）
    git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true
}

is_own_skill_link() {  # $1=リンク, $2=skill 名, $3=本 repo のルート
    local target root own_common
    target=$(readlink "$1" 2>/dev/null) || return 1
    # 相対パスはリンクのディレクトリ基準で解く（cwd 基準で解くと、自分の repo を指す相対リンクを他者と判定する）
    [[ $target == /* ]] || target="$(dirname "$1")/$target"
    # 今のチェックアウトそのもの（/tmp と /private/tmp の表記違いを含む）なら git を起動しない
    if [[ -e "$1" && "$(realpath "$target" 2>/dev/null)" == "$(realpath "$3/shared/skills/$2" 2>/dev/null)" ]]; then
        return 0
    fi
    case "$target" in
        */shared/skills/"$2"|*/shared/skills/"$2"/|*/claude/skills/"$2"|*/claude/skills/"$2"/) ;;
        *) return 1 ;;
    esac
    # 切れたリンクは、どの repo のものかを確かめようがないのでパターンで判定する
    [[ -e "$1" ]] || return 0
    root="${target%/*/skills/*}"
    own_common=$(own_git_common "$3")
    if [[ -n "$own_common" ]]; then
        [[ "$(own_git_common "$root")" == "$own_common" ]]
    else
        # git でないチェックアウト: 空どうしで一致させず、repo のルートの実パスで比べる
        [[ "$(realpath "$root" 2>/dev/null)" == "$(realpath "$3" 2>/dev/null)" ]]
    fi
}

echo -e "${BLUE}== check 8: Codex の skills (~/.agents/skills) ==${NC}"
if [ ! -d "$HOME/.codex" ]; then
    echo -e "${BLUE}[INFO]${NC} ~/.codex が無いので check 8 を省略します（Codex に展開されていない）"
else
    codex_skills_dir="$HOME/.agents/skills"
    wrong_own=()
    foreign=()
    unplaced=()
    for skill_dir in "$REPO_SKILLS"/*/; do
        name=$(basename "$skill_dir")
        [[ "$name" == _* ]] && continue
        target="$codex_skills_dir/$name"
        if [ -L "$target" ]; then
            link_target=$(readlink "$target")
            if [ "$link_target" = "${skill_dir%/}" ] || [ "$link_target" = "$skill_dir" ]; then
                continue
            fi
            if is_own_skill_link "$target" "$name" "$REPO_ROOT"; then
                wrong_own+=("$name (リンク先: $link_target)")
            else
                foreign+=("$name (他のリンク: $link_target)")
            fi
        elif [ -e "$target" ]; then
            foreign+=("$name (実体)")
        else
            unplaced+=("$name")
        fi
    done
    if [ ${#wrong_own[@]} -gt 0 ]; then
        for w in "${wrong_own[@]}"; do
            echo "  wrong: $w"
        done
        fail "${#wrong_own[@]} 件の Codex skill が、自分のリンクだが今のチェックアウトを指していません（別 worktree・切れたリンク）: $(printf '%s ' "${wrong_own[@]%% *}")— ./setup.sh install で張り替わります"
    fi
    if [ ${#foreign[@]} -gt 0 ]; then
        for f in "${foreign[@]}"; do
            echo "  foreign: $f"
        done
        warn "${#foreign[@]} 件は Codex では repo の skill ではありません（install は触らず skip した衝突）: $(printf '%s ' "${foreign[@]%% *}")"
    fi
    if [ ${#unplaced[@]} -gt 0 ]; then
        warn "${#unplaced[@]} 件の skill が ~/.agents/skills に未配置です — ./setup.sh install"
    fi
    if [ ${#wrong_own[@]} -eq 0 ] && [ ${#foreign[@]} -eq 0 ] && [ ${#unplaced[@]} -eq 0 ]; then
        pass "Codex の skills はすべて今のチェックアウトを指しています"
    fi
fi

# --- check 9: Codex の暗黙起動の抑止 ---
# Claude Code の disable-model-invocation: true は Codex に効かない。Codex は skill ごとの
# agents/openai.yaml の policy.allow_implicit_invocation: false で暗黙起動を止める。両者の集合が
# 食い違うと「Claude Code では手動専用なのに、Codex では自然文で起動する」状態が黙って成立する
# （手動専用にしたのは、有効な別実装に流れて副作用が出る skill のため）。repo だけで判定でき、HOME に依存しない。
# frontmatter だけを見る（本文のコードブロックに同じ行があっても数えない）。ファイルを直接 awk に渡し、
# パイプにしない（SIGPIPE + pipefail の fail-open を避ける。check 7 と同じ理由）
echo -e "${BLUE}== check 9: Codex の暗黙起動の抑止 (disable-model-invocation ⇔ agents/openai.yaml) ==${NC}"
disabled_names=()
policy_names=()
for skill_dir in "$REPO_SKILLS"/*/; do
    name=$(basename "$skill_dir")
    [[ "$name" == _* ]] && continue
    if [ -f "${skill_dir}SKILL.md" ] && awk '
        NR == 1 { if ($0 != "---") exit 1; next }
        /^---$/ { exit }
        /^disable-model-invocation:[[:space:]]*true/ { found = 1 }
        END { exit found ? 0 : 1 }
    ' "${skill_dir}SKILL.md"; then
        disabled_names+=("$name")
    fi
    if [ -f "${skill_dir}agents/openai.yaml" ] && awk '
        /^policy:[[:space:]]*$/ { in_policy = 1; next }
        /^[^[:space:]#]/ { in_policy = 0 }
        in_policy && /^[[:space:]]+allow_implicit_invocation:[[:space:]]*false[[:space:]]*$/ { found = 1 }
        END { exit found ? 0 : 1 }
    ' "${skill_dir}agents/openai.yaml"; then
        policy_names+=("$name")
    fi
done

if [ ${#disabled_names[@]} -eq 0 ]; then
    # 0 件どうしの一致を pass にしない。glob が空になった・frontmatter を読めなかったときに
    # 「0 == 0」で通り、検査していないことに気づけなくなる
    fail "disable-model-invocation: true の skill が 0 件です（skills の glob が空か、frontmatter の解析に失敗している）"
else
    missing_policy=()
    for name in "${disabled_names[@]}"; do
        case " ${policy_names[*]-} " in
            *" $name "*) ;;
            *) missing_policy+=("$name") ;;
        esac
    done
    extra_policy=()
    for name in ${policy_names[@]+"${policy_names[@]}"}; do
        case " ${disabled_names[*]} " in
            *" $name "*) ;;
            *) extra_policy+=("$name") ;;
        esac
    done
    if [ ${#missing_policy[@]} -gt 0 ]; then
        fail "disable-model-invocation: true なのに agents/openai.yaml (allow_implicit_invocation: false) が無い（Codex の自然文で暗黙起動する）: ${missing_policy[*]}"
    fi
    if [ ${#extra_policy[@]} -gt 0 ]; then
        fail "agents/openai.yaml (allow_implicit_invocation: false) があるのに disable-model-invocation: true でない（Codex だけ暗黙起動できない）: ${extra_policy[*]}"
    fi
    if [ ${#missing_policy[@]} -eq 0 ] && [ ${#extra_policy[@]} -eq 0 ]; then
        pass "disable-model-invocation: true の ${#disabled_names[@]} 件すべてに agents/openai.yaml (allow_implicit_invocation: false) があり、過不足はありません"
    fi
fi

# --- check 10: Codex の agents（TOML）の同期 ---
# TOML は agents の .md から install 時に生成する。.md を編集して install を忘れると、生成物が古いまま
# Codex で動き続ける（scripts と同じ「黙って古い物が動く」型）。ずれは install 待ちなので check 4 と同じく
# warn 止まりにし、差分は 1 件にまとめる
echo -e "${BLUE}== check 10: Codex の agents (TOML) の同期 ==${NC}"
if [ ! -d "$HOME/.codex" ]; then
    echo -e "${BLUE}[INFO]${NC} ~/.codex が無いので check 10 を省略します（Codex に展開されていない）"
elif ! command -v python3 >/dev/null 2>&1; then
    warn "check 10 (Codex の agents) をスキップしました（python3 が利用できない）"
else
    gen_dir=$(mktemp -d)
    if python3 "$REPO_ROOT/codex/gen-agents.py" --repo-root "$REPO_ROOT" --out "$gen_dir/out" 2>"$gen_dir/err"; then
        codex_agents_dir="$HOME/.codex/agents"
        toml_stale=()
        for gen in "$gen_dir"/out/*.toml; do
            [ -f "$gen" ] || continue
            name=$(basename "$gen")
            if [ ! -f "$codex_agents_dir/$name" ]; then
                toml_stale+=("$name (未配置)")
            elif ! cmp -s "$gen" "$codex_agents_dir/$name"; then
                toml_stale+=("$name (repo と差分あり・手書きと衝突)")
            fi
        done
        # 逆方向。生成元が無くなった生成物（agent の削除・改名）が残っていると、消した agent が Codex で使える
        for existing in "$codex_agents_dir"/*.toml; do
            [ -f "$existing" ] || continue
            case "$(head -n 1 "$existing")" in
                "# generated-by: gamonges-prompt setup.sh"*)
                    [ -f "$gen_dir/out/$(basename "$existing")" ] || toml_stale+=("$(basename "$existing") (生成元が無い生成物)")
                    ;;
            esac
        done
        if [ ${#toml_stale[@]} -eq 0 ]; then
            pass "Codex の agents（TOML）は shared/agents と同期しています"
        else
            for s in "${toml_stale[@]}"; do
                echo "  stale: $s"
            done
            warn "${#toml_stale[@]} 件の Codex agent が out of sync — run ./setup.sh install"
        fi
    else
        fail "agents の TOML を生成できません（shared/agents の frontmatter か codex/gen-agents.py を確認）: $(cat "$gen_dir/err")"
    fi
    rm -rf "$gen_dir"
fi

# setup.sh の marker_shape の複製（互いを source しないので複製し、7(1) が本体の一致を確かめる）。BEGIN・END は
# 行の完全一致で数える。部分一致で判定すると、install の差し替え（行の完全一致）と食い違う
marker_shape() {  # $1=ファイル, $2=BEGIN 行, $3=END 行 → none | ok | bad
    awk -v b="$2" -v e="$3" '
        $0 == b { nb++; if (open) bad = 1; open = 1; next }
        $0 == e { ne++; if (!open) bad = 1; open = 0; next }
        END { if (!nb && !ne) print "none"; else if (bad || open || nb != 1 || ne != 1) print "bad"; else print "ok" }
    ' "$1"
}

# --- check 11: Codex の AGENTS.md（ブロックとサイズ）---
# ~/.codex/AGENTS.md には共通規約と読み替え表の 2 ブロックが入る。Codex の取り込み機能や手編集で消える・
# 古くなることがあり、読み替え表が無い Codex は skill 本文の Claude の語彙（/name・AskUserQuestion 等）で止まる。
# また Codex は ~/.codex/AGENTS.md と repo 直下の AGENTS.md の合計が 32 KiB（project_doc_max_bytes）を
# 超えた分を読まず、後から読まれる repo 直下の AGENTS.md が欠ける
echo -e "${BLUE}== check 11: Codex の AGENTS.md（ブロックとサイズ）==${NC}"
if [ ! -d "$HOME/.codex" ]; then
    echo -e "${BLUE}[INFO]${NC} ~/.codex が無いので check 11 を省略します（Codex に展開されていない）"
else
    codex_md="$HOME/.codex/AGENTS.md"
    md_warn_before=$warn_count
    if [ ! -f "$codex_md" ]; then
        warn "~/.codex/AGENTS.md がありません — ./setup.sh install で作られます"
    else
        check_codex_block() {  # $1=表示名, $2=BEGIN 行, $3=END 行, $4=中身のファイル
            local shape
            shape=$(marker_shape "$codex_md" "$2" "$3" 2>/dev/null) || shape=error
            case "$shape" in
                none) warn "~/.codex/AGENTS.md に $1 のブロックがありません — ./setup.sh install で追記されます" ;;
                bad) warn "~/.codex/AGENTS.md の $1 のブロックのマーカーの並びが不正です（BEGIN 行 1 つ・その後ろに END 行 1 つが必要）。install は書き込まずに失敗するので、手で直してください" ;;
                error) warn "~/.codex/AGENTS.md を読めません（権限を確かめてください）" ;;
                *)
                    if ! cmp -s <(awk -v b="$2" -v e="$3" '$0 == e { on = 0 } on { print } $0 == b { on = 1 }' "$codex_md") "$4"; then
                        warn "~/.codex/AGENTS.md の $1 のブロックが $(basename "$4") と一致しません（取り込み機能による上書き・install 待ち）— ./setup.sh install"
                    fi
                    ;;
            esac
        }
        check_codex_block "共通規約" '<!-- BEGIN gamonges-prompt: skills 共通規約 -->' '<!-- END gamonges-prompt: skills 共通規約 -->' "$REPO_SHARED/global-rules.md"
        check_codex_block "Codex 読み替え表" '<!-- BEGIN gamonges-prompt: codex 読み替え表 -->' '<!-- END gamonges-prompt: codex 読み替え表 -->' "$REPO_ROOT/codex/codex-rules.md"

        # 読めないときはサイズを測らない（check_codex_block が warn 済み。set -euo pipefail の下で wc が verify ごと落ちる）
        if [ -r "$codex_md" ]; then
            codex_bytes=$(wc -c < "$codex_md" | tr -d ' ')
            repo_bytes=0
            if [ -f "$REPO_ROOT/AGENTS.md" ]; then
                repo_bytes=$(wc -c < "$REPO_ROOT/AGENTS.md" | tr -d ' ')
            fi
            total_bytes=$((codex_bytes + repo_bytes))
            if [ "$total_bytes" -ge 32768 ]; then
                warn "~/.codex/AGENTS.md (${codex_bytes} バイト) と repo 直下の AGENTS.md (${repo_bytes} バイト) の合計 ${total_bytes} バイトが、Codex の指示の上限 32 KiB (project_doc_max_bytes) に達しています。超えた分は読まれず、後から読まれる repo 直下の AGENTS.md が欠けます"
            fi
        fi
    fi
    if [ "$warn_count" -eq "$md_warn_before" ]; then
        pass "Codex の AGENTS.md は 2 ブロックが最新で、repo 直下と合わせて 32 KiB に収まっています"
    fi
fi

# --- check 12: Codex の hooks.json（自前 hook の位置と信頼）---
# Codex の hook の信頼は配列上の位置をキーにする（config.toml の
# [hooks.state."<hooks.json の絶対パス>:<event の snake_case>:<グループ index>:<hook index>"]）。
# 位置がずれた hook は中身が同じでも「要レビュー」になり、信頼し直すまでスキップされる（= ガードが黙って開く）。
#   (a) settings.json の自前 hook が、同じイベント・同じ matcher で、各イベントの先頭の自前グループとして登録されている
#   (b) 各自前 hook の位置キーが config.toml の [hooks.state] にある（無ければ「/hooks で信頼し直し待ち」）
# 自前の hook の判定は setup.sh と同じ「command が /.claude/scripts/ を含む」。$HOME での前方一致にしない
# （settings.json の command はリテラルの絶対パスなので、別の HOME では 0 件になり、何も検査せずに pass する）
echo -e "${BLUE}== check 12: Codex の hooks.json（自前 hook の位置と信頼）==${NC}"
if [ ! -d "$HOME/.codex" ]; then
    echo -e "${BLUE}[INFO]${NC} ~/.codex が無いので check 12 を省略します（Codex に展開されていない）"
elif ! command -v jq >/dev/null 2>&1; then
    warn "check 12 (Codex の hooks.json) をスキップしました（jq が利用できない）"
elif [ ! -f "$HOME/.codex/hooks.json" ]; then
    warn "~/.codex/hooks.json がありません — ./setup.sh install で作られます"
elif ! jq -se 'length == 1 and (.[0] | type == "object")' "$HOME/.codex/hooks.json" >/dev/null 2>&1; then
    # -s で {} {} のような複数の値も弾く（jq -e 'type == "object"' は [] {} を通す）。install は空・壊れた
    # hooks.json に書き込まずに失敗するので、install だけを案内しても直らない
    warn "~/.codex/hooks.json が空か、JSON のオブジェクトではありません。install は書き込まずに失敗するので、中身を確かめて直すか、退避して消してから ./setup.sh install"
else
    hooks_json="$HOME/.codex/hooks.json"
    codex_config="$HOME/.codex/config.toml"
    hook_warn_before=$warn_count

    # settings.json に自前 hook が 1 本も無いと、(a) は何も検査せずに通る
    settings_self=$(jq '[.hooks[]?[]? | .hooks[]? | (.command // "") | select(contains("/.claude/scripts/"))] | length' \
        "$REPO_CLAUDE/settings.json" 2>/dev/null || echo 0)
    if [ "${settings_self:-0}" -eq 0 ]; then
        warn "settings.json に自前 hook が 1 本もありません（check 12 は何も検査できない。settings.json を確かめてください）"
    fi

    # (a) 位置: 各イベントの先頭が、settings.json から作った自前グループの列と一致する
    if mismatched=$(jq -r --slurpfile s "$REPO_CLAUDE/settings.json" '
        def selfhook: ((.command // "") | contains("/.claude/scripts/"));
        . as $doc
        | ($s[0].hooks // {}) | to_entries[]
        | .key as $ev
        | ([ .value[] | (.hooks // []) as $hs | select($hs | any(.[]; selfhook)) | .hooks = [ $hs[] | select(selfhook) ] ]) as $gen
        | select(($gen | length) > 0)
        | select(((($doc.hooks // {})[$ev] // [])[0:($gen | length)]) != $gen)
        | $ev' "$hooks_json" 2>/dev/null); then
        while IFS= read -r ev; do
            [ -n "$ev" ] || continue
            warn "hooks.json の ${ev}: 自前グループが settings.json と同じ内容・同じ位置（先頭）で登録されていません。位置がずれると Codex の信頼が外れ、hook がスキップされます — ./setup.sh install"
        done <<< "$mismatched"
    else
        warn "hooks.json を解釈できません（壊れた JSON か、想定外の形）。check 12 (a) を判定できません"
    fi

    # (b) 信頼キー。config.toml は python3 で [hooks.state."…"] の見出しだけを拾う（3.9 には tomllib が無い）
    trusted_keys=""
    keys_ok=1
    if [ ! -f "$codex_config" ]; then
        warn "~/.codex/config.toml がありません。hook の信頼状態を確認できません（Codex で /hooks を開いて信頼してください）"
        keys_ok=0
    elif ! command -v python3 >/dev/null 2>&1; then
        warn "check 12 (b) をスキップしました（python3 が利用できない）"
        keys_ok=0
    elif [ ! -r "$codex_config" ]; then
        # 読めないまま python3 で読むと、set -euo pipefail の下で verify ごと落ちる
        warn "~/.codex/config.toml を読めません（権限を確かめてください）。hook の信頼状態を確認できません"
        keys_ok=0
    else
        trusted_keys=$(python3 - "$codex_config" <<'PY'
import re, sys
with open(sys.argv[1], encoding="utf-8", errors="replace") as fp:
    for line in fp:
        m = re.match(r'^\[hooks\.state\."([^"]+)"\]\s*$', line)
        if m:
            print(m.group(1))
PY
        )
    fi
    # 自前 hook の列挙は変数に取り、jq の失敗と 0 件を検知する（プロセス置換にすると、jq が途中で失敗しても
    # 見えず、そこまでの行だけを検査して PASS に見える）。他者のイベントの値が null・空配列でも、グループに
    # hooks が無くても止まらないよう // [] を当てる
    if ! own_rows=$(jq -r '(.hooks // {}) | to_entries[] | .key as $e | (.value // []) | to_entries[] | .key as $g
        | (.value.hooks // []) | to_entries[]
        | select((.value.command // "") | contains("/.claude/scripts/"))
        | [$e, ($g | tostring), (.key | tostring), (.value.command | split("/") | last)] | @tsv' "$hooks_json" 2>/dev/null); then
        warn "hooks.json の自前 hook を列挙できません（グループが配列のオブジェクトでない等、想定外の形）。check 12 (b) を判定できません"
        own_rows=""
    elif [ -z "$own_rows" ]; then
        warn "hooks.json に自前 hook が 1 件もありません — ./setup.sh install"
    fi
    while IFS=$'\t' read -r ev group_idx hook_idx script_name; do
        [ -n "$ev" ] || continue
        if [ "$keys_ok" -eq 1 ]; then
            snake=$(printf '%s' "$ev" | sed -E 's/([a-z])([A-Z])/\1_\2/g' | tr '[:upper:]' '[:lower:]')
            key="${hooks_json}:${snake}:${group_idx}:${hook_idx}"
            case $'\n'"$trusted_keys"$'\n' in
                *$'\n'"$key"$'\n'*) ;;
                *) warn "${ev} ${group_idx}:${hook_idx} (${script_name}) の信頼が config.toml に見つかりません。Codex の /hooks で信頼し直してください（位置や定義が変わった hook は信頼が外れ、スキップされます）" ;;
            esac
        fi
    done <<< "$own_rows"

    if [ "$warn_count" -eq "$hook_warn_before" ]; then
        pass "Codex の自前 hook は各イベントの先頭に登録され、信頼キーも config.toml にあります"
    fi
fi

# --- check 13: Codex の版が、前提を確かめた版と同じか ---
# 信頼ハッシュがスクリプトの中身を含まないこと（hook_hash）と apply_patch の文法は、codex/verified-codex-version の
# 版のソースとバイナリで確かめた前提。Codex を上げても何も失敗しないので、版が変わったことをここで知らせる
echo ""
echo -e "${BLUE}== check 13: Codex の版（前提を確かめた版との一致）==${NC}"
verified_file="${REPO_ROOT}/codex/verified-codex-version"
if [ ! -d "$HOME/.codex" ]; then
    echo -e "${BLUE}[INFO]${NC} ~/.codex が無いので check 13 を省略します（Codex に展開されていない）"
elif ! command -v codex >/dev/null 2>&1; then
    echo -e "${BLUE}[INFO]${NC} codex コマンドが見つからないので check 13 を省略します（版を比べられない）"
else
    verified_ver=$(tr -d '[:space:]' < "$verified_file" 2>/dev/null || true)
    current_ver=$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    if [ -z "$verified_ver" ]; then
        warn "codex/verified-codex-version を読めません（前提を確かめた Codex の版が分からない）"
    elif [ -z "$current_ver" ]; then
        warn "codex --version から版を読めません。check 13 を判定できません"
    elif [ "$current_ver" = "$verified_ver" ]; then
        pass "Codex ${current_ver} は前提を確かめた版と同じです"
    else
        warn "Codex が ${current_ver} です（前提を確かめた版は ${verified_ver}）。信頼ハッシュがスクリプトの中身を含まないか（codex-rs/hooks/src/engine/discovery.rs の hook_hash）と apply_patch の文法が変わっていないかを確かめ、codex/verified-codex-version を更新してください"
    fi
fi

# --- 挙動テスト (任意) ---
# 構造検証では捉えられない fail-open を捕まえる唯一の手段。既定では走らせない (数秒かかる)
if [ "$WITH_BEHAVIOR_TESTS" -eq 1 ]; then
    echo ""
    echo -e "${BLUE}== 挙動テスト: tests/test-guardrails.sh（hook の挙動）==${NC}"
    if bash "${REPO_SHARED}/scripts/tests/test-guardrails.sh"; then
        pass "hook の挙動テストがすべて通りました"
    else
        fail "hook の挙動テストに失敗があります (上記の [FAIL] を参照)"
    fi
    # setup.sh・verify・agents の TOML 生成の配置処理。sandbox HOME で実プロセスを走らせるので、実機の
    # ~/.claude・~/.codex には触れない。内部で verify-skills.sh（フラグ無し）を起動するが、再帰はしない
    echo ""
    echo -e "${BLUE}== 挙動テスト: tests/test-setup-codex.sh（配置処理）==${NC}"
    if bash "${REPO_SHARED}/scripts/tests/test-setup-codex.sh"; then
        pass "配置処理の挙動テストがすべて通りました"
    else
        fail "配置処理の挙動テストに失敗があります (上記の [FAIL] を参照)"
    fi
fi

echo ""
if [ "$fail_count" -gt 0 ]; then
    echo -e "${RED}${fail_count} check(s) failed${NC} (warn: ${warn_count})"
    exit 1
elif [ "$warn_count" -gt 0 ]; then
    echo -e "${YELLOW}Passed with ${warn_count} warning(s)${NC} (${expected} skills verified)"
else
    echo -e "${GREEN}All checks passed${NC} (${expected} skills verified)"
fi
