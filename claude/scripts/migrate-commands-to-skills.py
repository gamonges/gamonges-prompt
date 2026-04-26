#!/usr/bin/env python3
"""
claude/commands/*.md を claude/skills/<name>/SKILL.md へ移行する。

- frontmatter に name: <basename> を追加（既存 name: は警告のみ、上書きしない）
- frontmatter が無い場合は新規作成（description は最初の H1 から推定）
- 本文（frontmatter 以降）は完全コピー（sha256 ハッシュで検証）
- 全ファイル検証通過後に書き出し + 元ファイル削除を原子的に実行

使い方:
    python3 claude/scripts/migrate-commands-to-skills.py [--dry-run]

リポジトリルート（claude/ ディレクトリの親）から実行すること。
"""

from __future__ import annotations

import hashlib
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
COMMANDS_DIR = REPO_ROOT / "claude" / "commands"
SKILLS_DIR = REPO_ROOT / "claude" / "skills"


@dataclass
class Conversion:
    src: Path
    dst: Path
    new_text: str
    body_hash: str


def detect_crlf(text: str, path: Path) -> None:
    if "\r" in text:
        sys.exit(f"ERROR: CRLF detected in {path}. Convert to LF before migration.")


def split_frontmatter(text: str) -> tuple[list[str] | None, str]:
    """frontmatter (行のリスト) と本文を返す。frontmatter が無い場合は (None, text)。"""
    if not text.startswith("---\n"):
        return None, text

    end_match = re.search(r"\n---\n", text)
    if not end_match:
        return None, text

    fm_block = text[4 : end_match.start() + 1]
    body = text[end_match.end():]
    fm_lines = [line for line in fm_block.split("\n") if line]
    return fm_lines, body


def body_hash(text: str) -> str:
    """frontmatter ブロックを除いた本文の sha256 を返す。"""
    _, body = split_frontmatter(text)
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def first_h1(text: str) -> str | None:
    """frontmatter を除いた本文の最初の H1 行から見出しテキストを取得する。"""
    _, body = split_frontmatter(text)
    for line in body.splitlines():
        stripped = line.strip()
        if stripped.startswith("# "):
            return stripped[2:].strip()
    return None


def has_name_field(fm_lines: list[str]) -> bool:
    return any(re.match(r"^name\s*:", line) for line in fm_lines)


def build_skill_text(src: Path, original: str) -> str:
    """skill 形式の SKILL.md テキストを構築する。"""
    name = src.stem
    fm_lines, body = split_frontmatter(original)

    if fm_lines is None:
        description = first_h1(original) or name
        new_fm = [f"name: {name}", f'description: "{description}"']
        return "---\n" + "\n".join(new_fm) + "\n---\n" + original

    if has_name_field(fm_lines):
        print(f"WARN: {src} に既に name: フィールドがあります。上書きしません。", file=sys.stderr)
        new_fm_lines = fm_lines
    else:
        new_fm_lines = [f"name: {name}"] + fm_lines

    return "---\n" + "\n".join(new_fm_lines) + "\n---\n" + body


def plan_conversions() -> list[Conversion]:
    conversions: list[Conversion] = []
    for src in sorted(COMMANDS_DIR.glob("*.md")):
        original = src.read_text(encoding="utf-8")
        detect_crlf(original, src)

        new_text = build_skill_text(src, original)
        new_body = body_hash(new_text)
        original_body = body_hash(original)
        if new_body != original_body:
            sys.exit(
                f"ERROR: body hash mismatch for {src}\n"
                f"  original: {original_body}\n"
                f"  new:      {new_body}"
            )

        dst_dir = SKILLS_DIR / src.stem
        if dst_dir.exists():
            print(f"WARN: {dst_dir} は既に存在します。スキップします。", file=sys.stderr)
            continue

        conversions.append(Conversion(src=src, dst=dst_dir / "SKILL.md", new_text=new_text, body_hash=new_body))
    return conversions


def apply_conversions(conversions: list[Conversion]) -> None:
    for conv in conversions:
        conv.dst.parent.mkdir(parents=True, exist_ok=False)
        conv.dst.write_text(conv.new_text, encoding="utf-8")

    for conv in conversions:
        os.remove(conv.src)


def render_dry_run(conversions: list[Conversion]) -> None:
    print(f"# Dry run: {len(conversions)} conversions planned\n")
    for conv in conversions:
        rel_src = conv.src.relative_to(REPO_ROOT)
        rel_dst = conv.dst.relative_to(REPO_ROOT)
        print(f"- {rel_src} -> {rel_dst}  (body sha256: {conv.body_hash[:12]}...)")


def main() -> None:
    if not COMMANDS_DIR.is_dir():
        sys.exit(f"ERROR: commands directory not found: {COMMANDS_DIR}")
    if not SKILLS_DIR.is_dir():
        sys.exit(f"ERROR: skills directory not found: {SKILLS_DIR}")

    dry_run = "--dry-run" in sys.argv

    conversions = plan_conversions()
    if not conversions:
        print("移行対象のファイルがありません。")
        return

    if dry_run:
        render_dry_run(conversions)
        return

    apply_conversions(conversions)
    print(f"OK: {len(conversions)} files migrated.")


if __name__ == "__main__":
    main()
