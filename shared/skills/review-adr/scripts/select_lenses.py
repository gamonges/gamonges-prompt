"""review-adr のプロジェクト固有の観点を、ADR の中身で採点して選ぶ。

使い方:
  python3 select_lenses.py <対象 repo> <対象 repo>/tmp/adr-review/_target.md

出力（標準出力、1 行 1 候補の TSV。並びは選ぶ順）:
  得点  出現回数の合計  パス（repo からの相対）  selected|dropped|below  当たった語

終了コード: 0 = 採点できた（候補が 0 件でも 0）/ 2 = 引数の誤り・_target.md が読めない

規則の正本は reference/selection.md の「プロジェクト固有の観点」。
"""
import glob
import os
import re
import subprocess
import sys

PROG = "select_lenses.py"

# 本スキル群自身（試しのために対象 repo に置かれることがある）と、
# selection.md の「既存の観点」の表にある共有の観点と同名の定義
# （規則 4 の置き換えで扱う）は採点しない。表に行を足したらここにも足す
EXCLUDE = {
    "review-adr", "adr-decision-quality", "fact-check",
    "adr-premortem", "rollout-check", "adr-lineage",
    "adr-lens-reviewer",
    "adr", "security-auditor", "coupling-anatomy", "ddd-expert",
}

# skills・agents は、これを description に含むものだけが候補（rules は絞らない）
REVIEW_WORDS = ["レビュー", "review", "点検", "監査"]

# 開発の道具・成果物の一般名と英語の機能語。どの ADR にも出るので手がかりにならない
STOP = {
    "レビュー", "review", "スキル", "skill",
    "エージェント", "agent", "ガイド", "ルール",
    "adr", "code", "cli", "git", "github",
    "develop", "diff", "docs", "ドキュメント",
    "the", "and", "use", "when", "with",
    "for", "from", "that", "this",
}

# この数より多くの description に出る語は一般語として数えない
DF_MAX = 3
# 共通の語が 1 つだけなら偶然の一致とみなして選ばない
MIN_SCORE = 2
LIMIT = 5

# 2 文字の漢字（「対象」「直接」など）は一般語が多く、どの ADR にも当たるので数えない
WORD_RES = [
    re.compile(r"[A-Za-z][A-Za-z0-9_-]{2,}"),
    re.compile(r"[ァ-ヶー]{3,}"),
    re.compile(r"[一-龥々]{3,}"),
]


def read_lines(path):
    with open(path, encoding="utf-8") as f:
        return f.read().split("\n")


def description(path):
    """frontmatter の description。無ければ None（> や | の複数行も読む）"""
    try:
        lines = read_lines(path)
    except (OSError, UnicodeDecodeError):
        return None
    if not lines or lines[0] != "---":
        return None
    for i in range(1, len(lines)):
        line = lines[i]
        if line == "---":
            return None
        m = re.match(r"^description:\s*(.*)$", line)
        if not m:
            continue
        value = m.group(1).strip()
        if value in (">", ">-", "|", "|-"):
            parts = []
            for nxt in lines[i + 1:]:
                if nxt.startswith(" ") or nxt == "":
                    parts.append(nxt.strip())
                else:
                    break
            value = " ".join(parts)
        value = value.strip().strip('"').strip("'")
        return value or None
    return None


def words(text):
    found = set()
    for rx in WORD_RES:
        for w in rx.findall(text):
            found.add(w.lower())
    return found - STOP


def target_text(path):
    """frontmatter と「- 入力:」の行を除いた _target.md（小文字）。

    どちらも入力のパスを含み、パスの語（dresscode など）が部分一致で当たるため除く。
    """
    lines = read_lines(path)
    if lines and lines[0] == "---":
        for i in range(1, len(lines)):
            if lines[i] == "---":
                lines = lines[i + 1:]
                break
    kept = [ln for ln in lines if not ln.startswith("- 入力:")]
    return "\n".join(kept).lower()


def name_of(rel):
    parts = rel.split("/")
    if len(parts) >= 3 and parts[1] == "skills":
        return parts[2]
    return os.path.splitext(parts[-1])[0]


def scan(repo):
    pats = [
        ".claude/skills/*/SKILL.md",
        ".claude/agents/**/*.md",
        ".claude/rules/**/*.md",
    ]
    paths = set()
    for pat in pats:
        paths.update(glob.glob(os.path.join(repo, pat), recursive=True))
    descs = {}
    for p in sorted(paths):
        rel = os.path.relpath(p, repo).replace(os.sep, "/")
        if name_of(rel) in EXCLUDE:
            continue
        d = description(p)
        if d:
            descs[rel] = d
    return descs


def repo_name(repo):
    """対象 repo の名前（小文字）。取れなければ空文字。

    worktree の作業ツリーの名前はブランチ名なので、origin の URL の末尾か、
    共有の .git の親の名前を使う。
    """
    def git(*args):
        try:
            r = subprocess.run(["git", "-C", repo] + list(args),
                               capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.SubprocessError):
            return ""
        return r.stdout.strip() if r.returncode == 0 else ""
    url = git("remote", "get-url", "origin")
    if url:
        name = re.split(r"[/:]", url.rstrip("/"))[-1]
        if name.endswith(".git"):
            name = name[:-4]
        return name.lower()
    common = git("rev-parse", "--path-format=absolute", "--git-common-dir")
    if common:
        return os.path.basename(os.path.dirname(common.rstrip("/"))).lower()
    return ""


def is_candidate(rel, desc):
    if rel.startswith(".claude/rules/"):
        return True
    low = desc.lower()
    return any(w.lower() in low for w in REVIEW_WORDS)


def main(argv):
    if len(argv) != 3:
        sys.stderr.write(PROG + ": 使い方: " + PROG + " <対象 repo> <_target.md>\n")
        return 2
    repo, target = argv[1], argv[2]
    if not os.path.isdir(repo):
        sys.stderr.write(PROG + ": 対象 repo が無い: " + repo + "\n")
        return 2
    try:
        adr = target_text(target)
    except (OSError, UnicodeDecodeError) as e:
        sys.stderr.write(PROG + ": _target.md を読めない: " + str(e) + "\n")
        return 2

    descs = scan(repo)
    # 製品名は repo の名前に出る（dresscode-backend の dress など）。どの ADR にも出るので数えない
    own = repo_name(repo)
    df = {}
    for d in descs.values():
        for w in words(d):
            df[w] = df.get(w, 0) + 1

    rows = []
    for rel, d in descs.items():
        if not is_candidate(rel, d):
            continue
        hit = sorted(w for w in words(d)
                     if df[w] <= DF_MAX and w in adr and w not in own)
        occ = sum(adr.count(w) for w in hit)
        rows.append((len(hit), occ, rel, hit))
    # 得点 → 出現回数の合計（ADR がその話題に紙面を割いているほど上）→ パスの辞書順
    rows.sort(key=lambda r: (-r[0], -r[1], r[2]))

    taken = 0
    for score, occ, rel, hit in rows:
        if score < MIN_SCORE:
            status = "below"
        elif taken < LIMIT:
            status = "selected"
            taken += 1
        else:
            status = "dropped"
        cols = [str(score), str(occ), rel, status, " ".join(hit)]
        sys.stdout.write("\t".join(cols) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
