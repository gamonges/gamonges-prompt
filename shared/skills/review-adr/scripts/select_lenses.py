"""review-adr のプロジェクト固有の観点を、ADR の中身で採点して選ぶ。

使い方:
  python3 select_lenses.py <対象 repo> <対象 repo>/tmp/adr-review/_target.md

出力（標準出力、1 行 1 候補の TSV。並びは選ぶ順）:
  得点  出現回数の合計  パス（repo からの相対）  selected|dropped|below  当たった語  書き先の名前

読めない定義（開けない・UTF-8 でない・skills と agents で description が無い）は採点から
外し、標準エラーに 1 行ずつ出す（rc は 0 のまま。TSV には混ぜない）。

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
# （規則 4 の置き換えで扱う）は採点しない。表に行を足したらここにも足す。
# 当てるのは skills・agents だけ（rules は観点の定義と名前が同じでも別物の規約）
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

# 書き先のファイル名（tmp/adr-review/<名前>.md）として使えない名前。
# Codex・集約・自己レビューの結果と、_ で始まるスナップショット、共有の観点の結果に重なる
RESERVED = {"codex", "unified", "adr-self-review"}

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


class Unreadable(Exception):
    pass


def read_lines(path):
    # utf-8-sig: 先頭の BOM を捨てる（残すと 1 行目が「---」に一致せず、定義を黙って落とす）
    with open(path, encoding="utf-8-sig") as f:
        return f.read().split("\n")


def close_quote(text, quote, start):
    """引用符の値の閉じの位置。YAML のエスケープ（一重引用符の ''・二重引用符の \\"）は読み飛ばす。無ければ -1"""
    i = start
    while i < len(text):
        c = text[i]
        if quote == '"' and c == "\\":
            i += 2
            continue
        if c == quote:
            if quote == "'" and text[i + 1:i + 2] == "'":
                i += 2
                continue
            return i
        i += 1
    return -1


def unescape(text, quote):
    return text.replace("''", "'") if quote == "'" else text.replace('\\"', '"')


def uncomment(line):
    """plain scalar の行から YAML のコメントを捨てる（行頭の # と、空白の後の # 以降）"""
    stripped = line.strip()
    if stripped.startswith("#"):
        return ""
    return re.split(r"\s#", stripped, maxsplit=1)[0].strip()


def description(path):
    """frontmatter の description。frontmatter・description が無ければ None。

    値が次の行から始まる定義・> や | のブロック・複数行の plain scalar も読む
    （続きは先頭が空白の行と空行。インデントの無い行か --- で止まる）。
    開けない・UTF-8 でないときは Unreadable を投げる。
    """
    try:
        lines = read_lines(path)
    except (OSError, UnicodeDecodeError) as e:
        raise Unreadable(str(e))
    if not lines or lines[0] != "---":
        return None
    for i in range(1, len(lines)):
        line = lines[i]
        if line == "---":
            return None
        m = re.match(r"^description:\s*(.*)$", line)
        if not m:
            continue
        head = m.group(1).strip()
        # ブロックの指示子（>・| に +・-・インデントの数字、後ろにコメント）
        block = re.match(r"^[>|][+-]?[0-9]?[+-]?\s*(#.*)?$", head) is not None
        quote = head[:1] if head[:1] in ("'", '"') else ""
        if quote:
            # 引用符の値は閉じの引用符まで（中の「 #」はコメントではなく、後ろの # 以降はコメント）
            end = close_quote(head, quote, 1)
            if end > 0:
                return unescape(head[1:end], quote).strip() or None
        parts = [] if block else [head if quote else uncomment(head)]
        for nxt in lines[i + 1:]:
            if nxt == "---" or not (nxt.startswith((" ", "\t")) or nxt == ""):
                break
            end = close_quote(nxt, quote, 0) if quote else -1
            if end >= 0:
                parts.append(unescape(nxt[:end], quote).strip())
                break
            parts.append(nxt.strip() if block or quote else uncomment(nxt))
        value = " ".join(x for x in parts if x)
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

    どちらも入力のパスを含み、パスの語（repo の名前など）が部分一致で当たるため除く。
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


def long_name(rel):
    """.claude/ を除き、拡張子を除き、/ を - にした名前（rules/frontend/testing.md → rules-frontend-testing）"""
    return os.path.splitext(rel[len(".claude/"):])[0].replace("/", "-")


def out_names(rels):
    """書き先の名前を、パスの辞書順で 1 本ずつ決める（同じ入力なら毎回同じ名前）。

    既定名 → 長い名前 → 長い名前-2・-3… の順に、予約名とそれまでに決めた名前に当たらない
    最初のものを採る。既定名が 2 回以上出るときは、どちらにも既定名を使わない
    （先に来た方だけが短い名前になると、どちらがどの定義か読み手が取り違えるため）。
    """
    count = {}
    for rel in rels:
        count[name_of(rel)] = count.get(name_of(rel), 0) + 1

    def taken(n):
        return n in used or n in RESERVED or n in EXCLUDE or n.startswith("_")

    used = set()
    names = {}
    for rel in sorted(rels):
        cands = [] if count[name_of(rel)] > 1 else [name_of(rel)]
        cands.append(long_name(rel))
        n = next((c for c in cands if not taken(c)), None)
        k = 2
        while n is None:
            c = long_name(rel) + "-" + str(k)
            n = None if taken(c) else c
            k += 1
        used.add(n)
        names[rel] = n
    return names


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
        is_rule = rel.startswith(".claude/rules/")
        if not is_rule and name_of(rel) in EXCLUDE:
            continue
        try:
            d = description(p)
        except Unreadable:
            sys.stderr.write(PROG + ": 読めない定義: " + rel + "\n")
            continue
        if d:
            descs[rel] = d
        elif not is_rule:
            # rules は paths: だけの frontmatter を持つことが多いので、毎回出すと雑音になる
            sys.stderr.write(PROG + ": description が無い: " + rel + "\n")
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


def hits(w, adr):
    """ADR に語が出る回数。英字で始まる語は単語として数える（auth を author に当てない）。

    カタカナ・漢字の語は部分一致（日本語の文に単語の区切りは無い）。
    """
    if re.match(r"[a-z]", w):
        return len(re.findall(r"(?<![a-z0-9_-])" + re.escape(w) + r"(?![a-z0-9_-])", adr))
    return adr.count(w)


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
    # 製品名は repo の名前に出る（acme-backend の acme など）。どの ADR にも出るので数えない
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
                     if df[w] <= DF_MAX and hits(w, adr) and w not in own)
        occ = sum(hits(w, adr) for w in hit)
        rows.append((len(hit), occ, rel, hit))
    # 得点 → 出現回数の合計（ADR がその話題に紙面を割いているほど上）→ パスの辞書順
    rows.sort(key=lambda r: (-r[0], -r[1], r[2]))

    names = out_names([r[2] for r in rows])
    taken = 0
    for score, occ, rel, hit in rows:
        if score < MIN_SCORE:
            status = "below"
        elif taken < LIMIT:
            status = "selected"
            taken += 1
        else:
            status = "dropped"
        cols = [str(score), str(occ), rel, status, " ".join(hit), names[rel]]
        sys.stdout.write("\t".join(cols) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
