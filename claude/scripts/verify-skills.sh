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

echo ""
echo -e "${GREEN}All checks passed${NC} (${expected} skills verified)"
