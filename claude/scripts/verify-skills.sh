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
#
# 使い方:
#   ./claude/scripts/verify-skills.sh
#
set -euo pipefail

REPO_SKILLS="$(cd "$(dirname "$0")/.." && pwd)/skills"
INSTALLED_SKILLS="$HOME/.claude/skills"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

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

# 2. frontmatter "name" field (_ プレフィックスも検証対象)
missing=()
for skill in "$REPO_SKILLS"/*/SKILL.md; do
    if ! head -10 "$skill" | grep -q "^name:"; then
        missing+=("$skill")
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
REPO_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLED_SCRIPTS="$HOME/.claude/scripts"
stale=()
for script in "$REPO_SCRIPTS"/*.sh "$REPO_SCRIPTS"/*.py; do
    [ -f "$script" ] || continue
    name=$(basename "$script")
    installed="$INSTALLED_SCRIPTS/$name"

    if [ -L "$installed" ]; then
        stale+=("$name (旧形式の symlink)")
    elif [ ! -f "$installed" ]; then
        stale+=("$name (未インストール)")
    elif ! cmp -s "$script" "$installed"; then
        stale+=("$name (repo と差分あり)")
    fi
done

if [ ${#stale[@]} -eq 0 ]; then
    pass "All scripts are in sync with repo"
else
    for s in "${stale[@]}"; do
        echo "  stale: $s"
    done
    warn "${#stale[@]} scripts out of sync — run ./setup.sh install"
fi

# 5. skill listing の description 総文字数 (budget 監視。閾値はモデル依存のため fail にしない)
#    disable-model-invocation: true の skill は listing に載らないため除外する
listing_report=$(python3 - "$REPO_SKILLS" <<'PY'
import glob, os, re, sys
root = sys.argv[1]
listed = hidden = chars = 0
over = []
for f in sorted(glob.glob(os.path.join(root, "*", "SKILL.md"))):
    if os.path.basename(os.path.dirname(f)).startswith("_"):
        continue
    text = open(f, encoding="utf-8").read()
    m = re.search(r"^---\n(.*?)\n---", text, re.S)
    if not m:
        continue
    fm = m.group(1)
    d = re.search(r"^description:\s*(.*(?:\n[ \t]+.*)*)", fm, re.M)
    desc = d.group(1).strip() if d else ""
    if re.search(r"^disable-model-invocation:\s*true", fm, re.M):
        hidden += 1
        continue
    listed += 1
    chars += len(desc)
    if len(desc) > 120:
        over.append(f"{os.path.basename(os.path.dirname(f))}({len(desc)})")
print(f"{listed}\t{hidden}\t{chars}\t{' '.join(over)}")
PY
)
listed_n=$(echo "$listing_report" | cut -f1)
hidden_n=$(echo "$listing_report" | cut -f2)
chars_n=$(echo "$listing_report" | cut -f3)
over_list=$(echo "$listing_report" | cut -f4)

echo -e "${GREEN}[INFO]${NC} skill listing: ${listed_n} 件 / ${chars_n} 文字 (listing 対象外: ${hidden_n} 件)"
if [ -n "$over_list" ]; then
    warn "description が 120 字を超える skill: ${over_list}"
fi

echo ""
echo -e "${GREEN}All checks passed${NC} (${expected} skills verified)"
