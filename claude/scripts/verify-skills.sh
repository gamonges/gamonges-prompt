#!/bin/bash
#
# verify-skills.sh
# ----------------
# claude/skills/ と ~/.claude/skills/ の整合性を機械的に検証する。
#
# 検証項目:
# 1. SKILL.md ファイル数の一致 (リポ vs インストール先)
# 2. 各 SKILL.md の frontmatter に name フィールドが存在すること
# 3. 各 ~/.claude/skills/<name> が本リポを指す symlink であること
# 4. claude/scripts/ と ~/.claude/scripts/ の同期状態 (実体コピー方式のため。warn 止まり)
# 5. skill listing の description 総文字数 (budget 監視。warn 止まり)
#
# 依存: check 5 のみ python3 を使う。利用できない場合は check 5 をスキップして続行する。
#
# 終了コード: fail が 1 件でもあれば 1、それ以外は 0 (warn があっても 0)
#
# 使い方:
#   ./claude/scripts/verify-skills.sh
#
set -euo pipefail

# 自スクリプトの所在から派生させる。$0 と ${BASH_SOURCE[0]} を混在させず 1 箇所で算出する
REPO_CLAUDE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${REPO_CLAUDE}/.." && pwd)"
REPO_SKILLS="${REPO_CLAUDE}/skills"
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

# 3. symlink integrity (_ プレフィックスは雛形扱いで対象外)
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
REPO_SCRIPTS="${REPO_CLAUDE}/scripts"
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
        warn ".installed-from が指すチェックアウトがありません: $from_dir（install 元が削除された可能性）"
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
if listing_report=$(python3 - "$REPO_SKILLS" <<'PY'
import glob, json, os, re, sys
root = sys.argv[1]

# settings.json の skillOverrides も listing 対象の判定に含める。frontmatter だけを見ると
# name-only / user-invocable-only / off にした skill が「まだ listing に載っている」と
# 数えられ、解消しようのない warn が常時点灯して検出力を失う。
# 読み取り専用・失敗時は無視することで結合を最小に留める
overrides = {}
try:
    with open(os.path.join(root, os.pardir, "settings.json"), encoding="utf-8") as fp:
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
        warn "skillOverrides に実在しない skill のキーがあります: ${unknown_ov}（設定が黙って無効になる。plugin 由来 skill には skillOverrides が効かないので /plugin を使う）"
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
            fail "登録済み hook が repo に存在しません: $hook_name (settings.json に登録済み / claude/scripts/ に無い)"
        elif [ ! -x "$cmd" ]; then
            warn "登録済み hook が未配置または実行不可: $cmd (./setup.sh install が必要)"
        fi
    done <<< "$hook_cmds"
else
    warn "check 6 (hook の実体) をスキップしました（python3 が利用できないか settings.json の解析に失敗）"
fi

# 7. 同期状態を見る 3 実装が逆走査 (orphan 検出) を持っているか
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
check_reverse_scan "hook-check-scripts-sync.sh" "$(cat "$REPO_CLAUDE/scripts/hook-check-scripts-sync.sh")"
check_reverse_scan "verify-skills.sh (check 4)" "$(cat "$REPO_CLAUDE/scripts/verify-skills.sh")"
check_reverse_scan "setup.sh:show_status()"     "$(sed -n '/^show_status()/,/^}/p' "$REPO_ROOT/setup.sh")"

# scripts を走査する箇所は *.sh と *.py の glob を対で持つ。片方を書き忘れると
# 「.py ファイルだけ処理されない」という静かな取りこぼしになり、出力からは気づけない
check_glob_pair() {  # $1=表示名, $2=検査対象のテキスト
    printf '%s' "$2" | grep -q '\*\.py' \
        || warn "$1 に *.py の走査がありません（*.sh との glob 対の揃え忘れ）"
}
check_glob_pair "hook-check-scripts-sync.sh" "$(cat "$REPO_CLAUDE/scripts/hook-check-scripts-sync.sh")"
check_glob_pair "verify-skills.sh (check 4)" "$(cat "$REPO_CLAUDE/scripts/verify-skills.sh")"
check_glob_pair "setup.sh:install_scripts()" "$(sed -n '/^install_scripts()/,/^}/p' "$REPO_ROOT/setup.sh")"
check_glob_pair "setup.sh:show_status()"     "$(sed -n '/^show_status()/,/^}/p' "$REPO_ROOT/setup.sh")"

echo ""
if [ "$fail_count" -gt 0 ]; then
    echo -e "${RED}${fail_count} check(s) failed${NC} (warn: ${warn_count})"
    exit 1
elif [ "$warn_count" -gt 0 ]; then
    echo -e "${YELLOW}Passed with ${warn_count} warning(s)${NC} (${expected} skills verified)"
else
    echo -e "${GREEN}All checks passed${NC} (${expected} skills verified)"
fi
