#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""agents の .md（Claude Code の subagent 定義）から Codex の custom agent の TOML を生成する。

使い方:
    gen-agents.py --out DIR [--repo-root DIR] [--src DIR]

    --out        出力先。<name>.toml を 1 件ずつ書く
    --repo-root  生成ヘッダの source に書く相対パスの基準（既定: 本スクリプトの 1 つ上）
    --src        入力。.md を再帰的に探す（既定: <repo-root>/shared/agents）

終了コード: 0 = 成功 / 1 = 入力の検証エラー（何も書かない） / 2 = 使い方の誤り

設計:
- Python 3.9 の標準ライブラリだけで動く（tomllib は 3.11 以降）。macOS の /usr/bin/python3 は 3.9.6
- frontmatter は最小のパーサで読む。受け付けるのは `key: value`・`key:` + `- item` のリスト・
  `>` / `|` のブロック。未知のキー・構文は黙って読み飛ばさず、エラーにする
  （黙って落とした値は、Codex で agent の権限や挙動が変わっても気づけない）
- 全件を検証してから書く。途中で失敗しても半端な出力を残さない
- 生成物の 1 行目が「自分が置いたもの」の目印。setup.sh の orphan 判定・uninstall がこれを見る
"""
import argparse
import json
import os
import re
import sys

HEADER_PREFIX = "# generated-by: gamonges-prompt setup.sh"

# 受け付ける frontmatter のキー。現行の 35 件はこの 5 つだけ。増えたら生成器を意図して直す
ALLOWED_KEYS = ("name", "description", "tools", "model", "skills")

# Codex の組み込み agent。仕様上は custom agent が優先されるので禁止ではないが、
# 意図せず組み込み agent を置き換えないための安全側の判断
BUILTIN_NAMES = ("default", "worker", "explorer")

# これらのどれかを tools に持つ agent は書き込める。どれも無ければ read-only にする
WRITE_TOOLS = ("Write", "Edit", "MultiEdit", "NotebookEdit")

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")
KEY_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*):[ \t]*(.*)$")
ITEM_RE = re.compile(r"^[ \t]+-[ \t]+(.+)$")


class GenError(Exception):
    pass


def split_frontmatter(text, path):
    lines = text.split("\n")
    if lines[0].rstrip("\r") != "---":
        raise GenError("%s: 先頭が --- の frontmatter がありません" % path)
    for i in range(1, len(lines)):
        if lines[i].rstrip() == "---":
            return lines[1:i], "\n".join(lines[i + 1:])
    raise GenError("%s: frontmatter が --- で閉じられていません" % path)


def read_block_scalar(lines, i, style):
    """`>` / `|` のブロックを読み、(文字列, 次の行) を返す。末尾の改行は常に落とす"""
    block = []
    while i < len(lines) and (not lines[i].strip() or lines[i][0] in " \t"):
        block.append(lines[i])
        i += 1
    while block and not block[-1].strip():
        block.pop()
    indents = [len(b) - len(b.lstrip(" \t")) for b in block if b.strip()]
    margin = min(indents) if indents else 0
    stripped = [b[margin:] if b.strip() else "" for b in block]
    if style.startswith(">"):
        # 折りたたみ: 連続する行は空白 1 つでつなぎ、空行は段落の区切りとして改行にする
        out = []
        paragraph = []
        for b in stripped:
            if b:
                paragraph.append(b.rstrip())
            elif paragraph:
                out.append(" ".join(paragraph))
                paragraph = []
        if paragraph:
            out.append(" ".join(paragraph))
        return "\n".join(out), i
    return "\n".join(stripped), i


def parse_frontmatter(fm_lines, path):
    data = {}
    i = 0
    while i < len(fm_lines):
        line = fm_lines[i].rstrip("\r")
        if not line.strip() or line.lstrip().startswith("#"):
            i += 1
            continue
        m = KEY_RE.match(line)
        if not m:
            raise GenError("%s: 解釈できない frontmatter の行: %r" % (path, line))
        key, rest = m.group(1), m.group(2).rstrip()
        i += 1
        if key not in ALLOWED_KEYS:
            raise GenError(
                "%s: 未知の frontmatter キー %r（受け付けるのは %s。生成器を意図して直す。"
                "Codex に渡さないキーなら codex/gen-agents.py の ALLOWED_KEYS に足す（TOML には出ない））"
                % (path, key, ", ".join(ALLOWED_KEYS))
            )
        if key in data:
            raise GenError("%s: frontmatter キー %r が重複しています" % (path, key))
        if rest in (">", ">-", "|", "|-"):
            data[key], i = read_block_scalar(fm_lines, i, rest)
        elif rest == "":
            items = []
            while i < len(fm_lines):
                im = ITEM_RE.match(fm_lines[i].rstrip("\r"))
                if not im:
                    break
                item = im.group(1).strip()
                check_plain(path, key, item)
                items.append(item)
                i += 1
            if not items:
                raise GenError("%s: %r の値が空です（リスト項目も無い）" % (path, key))
            data[key] = items
        else:
            check_plain(path, key, rest)
            data[key] = rest
    return data


def check_plain(path, key, value):
    """スカラーの値・リスト項目を、プレーンな文字列として受け付けてよいか確かめる"""
    if not value:
        raise GenError("%s: %r の値（リスト項目）が空です" % (path, key))
    if value[0] in "'\"[{&*!@`%>|":
        # 引用符・フロー形式・アンカー・未対応のブロック指示子（>+ や |2 等）は、
        # YAML としての解釈と生成器の解釈が割れうる。プレーンな文字列として黙って通さない
        raise GenError("%s: %r の値の書式は未対応です: %r" % (path, key, value))
    if " #" in value:
        raise GenError("%s: %r の値に ' #' があります（YAML ではコメントになり解釈が割れる）" % (path, key))


def as_list(value):
    if isinstance(value, list):
        return value
    return [v.strip() for v in value.split(",") if v.strip()]


def toml_string(value):
    """TOML の basic string にする。

    json.dumps の出力（\\" \\\\ \\n \\t \\uXXXX）は TOML の basic string と互換。ただし U+007F（DEL）は
    json.dumps がエスケープせず、TOML の basic string では制御文字として禁止されている
    （Codex の読み込みが失敗する）ので \\u007f に置き換える。"""
    return json.dumps(value, ensure_ascii=False).replace("\x7f", "\\u007f")


def build_agent(path, rel, text):
    fm_lines, body = split_frontmatter(text, path)
    data = parse_frontmatter(fm_lines, path)
    for required in ("name", "description"):
        if not data.get(required):
            raise GenError("%s: frontmatter に %s がありません" % (path, required))
    name = data["name"]
    stem = os.path.splitext(os.path.basename(path))[0]
    if name != stem:
        raise GenError(
            "%s: name %r とファイル名 %r が一致しません（setup.sh は basename で配置する）" % (path, name, stem)
        )
    if not NAME_RE.match(name):
        raise GenError("%s: name %r は英数字・ハイフン・アンダースコアだけにしてください" % (path, name))
    if name in BUILTIN_NAMES:
        raise GenError(
            "%s: name %r は Codex の組み込み agent と重なります（意図せず置き換えないため止める）" % (path, name)
        )

    # Codex は developer_instructions が空の agent を拒否する（cannot be blank）。skills の前置きを足す前に判定する
    if not body.strip():
        raise GenError("%s: 本文が空です（Codex は developer_instructions が空の agent を読み込まない）" % path)
    instructions = body.strip("\n")
    skills = as_list(data["skills"]) if "skills" in data else []
    if skills:
        # Claude Code の skills: は frontmatter で preload される。Codex には同じ機構が無いので、
        # 本文の先頭で SKILL.md を読ませる。読めない状態で作業を始めると、判定基準なしで動く
        preamble = "\n".join(
            "作業を始める前に ~/.agents/skills/%s/SKILL.md を読む。読めなければ作業を始めずに停止して報告する。" % s
            for s in skills
        )
        instructions = preamble + "\n\n" + instructions

    lines = [
        "%s — source: %s — 手で編集しない" % (HEADER_PREFIX, rel),
        "name = %s" % toml_string(name),
        "description = %s" % toml_string(data["description"]),
    ]
    # tools が無い agent は Claude Code では全ツールを継承する。read-only にすると、
    # 書き込みが要る agent が Codex で黙って書けなくなるので、sandbox_mode は出さない（親を継承）
    if "tools" in data:
        # YAML では null・~・true・false（大文字小文字を問わない）は文字列ではない。tools: null は Claude Code では
        # tools 無し（全ツールの継承）なので、文字列として read-only に分類すると権限の向きが逆になる
        if isinstance(data["tools"], str) and data["tools"].lower() in ("null", "~", "true", "false"):
            raise GenError("%s: tools の値 %r は YAML では null・真偽値です。tools を省くか、リストで書いてください" % (path, data["tools"]))
        tools = as_list(data["tools"])
        if not any(t in WRITE_TOOLS for t in tools):
            lines.append('sandbox_mode = "read-only"')
    # model: は出さない（親のモデルを継承する。Claude のモデル名は Codex では意味を持たない）
    lines.append("developer_instructions = %s" % toml_string(instructions))
    return name, "\n".join(lines) + "\n"


def collect(src, repo_root):
    results = {}
    sources = {}
    paths = []
    for dirpath, _dirs, files in os.walk(src):
        for fname in files:
            if fname.endswith(".md") and fname != "README.md":
                paths.append(os.path.join(dirpath, fname))
    for path in sorted(paths):
        rel = os.path.relpath(path, repo_root).replace(os.sep, "/")
        try:
            with open(path, encoding="utf-8") as fp:
                text = fp.read()
        except UnicodeDecodeError as exc:
            raise GenError("%s: UTF-8 として読めません: %s" % (path, exc))
        name, toml = build_agent(path, rel, text)
        if name in results:
            raise GenError("name %r が重複しています: %s と %s" % (name, sources[name], path))
        results[name] = toml
        sources[name] = path
    return results


def main(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser(description="agents の .md から Codex の custom agent の TOML を生成する")
    parser.add_argument("--out", required=True)
    parser.add_argument("--repo-root", default=os.path.dirname(here))
    parser.add_argument("--src", default=None)
    args = parser.parse_args(argv)
    src = args.src or os.path.join(args.repo_root, "shared", "agents")
    if not os.path.isdir(src):
        sys.stderr.write("gen-agents.py: 入力ディレクトリがありません: %s\n" % src)
        return 1
    try:
        results = collect(src, args.repo_root)
    except GenError as exc:
        sys.stderr.write("gen-agents.py: %s\n" % exc)
        return 1
    if not results:
        sys.stderr.write("gen-agents.py: %s に agent が 1 件もありません\n" % src)
        return 1
    os.makedirs(args.out, exist_ok=True)
    for name in sorted(results):
        with open(os.path.join(args.out, name + ".toml"), "w", encoding="utf-8", newline="\n") as fp:
            fp.write(results[name])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
