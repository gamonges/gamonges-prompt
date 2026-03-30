#!/usr/bin/env python3
"""Claude Code statusline: Fine Bar + Gradient with git branch and directory name."""
import json
import os
import subprocess
import sys

data = json.load(sys.stdin)

BLOCKS = ' ▏▎▍▌▋▊▉█'
R = '\033[0m'
DIM = '\033[2m'


def gradient(pct):
    if pct < 50:
        r = int(pct * 5.1)
        return f'\033[38;2;{r};200;80m'
    else:
        g = int(200 - (pct - 50) * 4)
        return f'\033[38;2;255;{max(g, 0)};60m'


def bar(pct, width=10):
    pct = min(max(pct, 0), 100)
    filled = pct * width / 100
    full = int(filled)
    frac = int((filled - full) * 8)
    b = '█' * full
    if full < width:
        b += BLOCKS[frac]
        b += '░' * (width - full - 1)
    return b


def fmt(label, pct):
    p = round(pct)
    return f'{label} {gradient(pct)}{bar(pct)} {p}%{R}'


def get_git_branch(cwd):
    try:
        result = subprocess.run(
            ['git', 'branch', '--show-current'],
            capture_output=True, text=True, cwd=cwd, timeout=1,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
        result = subprocess.run(
            ['git', 'rev-parse', '--short', 'HEAD'],
            capture_output=True, text=True, cwd=cwd, timeout=1,
        )
        if result.returncode == 0 and result.stdout.strip():
            return f'HEAD ({result.stdout.strip()})'
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    return None


model = data.get('model', {}).get('display_name', 'Claude')
cwd = data.get('workspace', {}).get('current_dir', '')
parts = [model]

if cwd:
    parts.append(f'\uf07c {os.path.basename(cwd)}')

branch = get_git_branch(cwd) if cwd else None
if branch:
    parts.append(f'\ue725 {branch}')

ctx = data.get('context_window', {}).get('used_percentage')
if ctx is not None:
    parts.append(fmt('ctx', ctx))

five = data.get('rate_limits', {}).get('five_hour', {}).get('used_percentage')
if five is not None:
    parts.append(fmt('5h', five))

week = data.get('rate_limits', {}).get('seven_day', {}).get('used_percentage')
if week is not None:
    parts.append(fmt('7d', week))

print(f'{DIM}│{R}'.join(f' {p} ' for p in parts), end='')
