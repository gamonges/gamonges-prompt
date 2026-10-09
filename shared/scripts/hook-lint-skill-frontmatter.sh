#!/usr/bin/env bash
# PreToolUse hook: SKILL.md の frontmatter lint (name / description 必須 + トリガー語推奨)
# 公式: https://code.claude.com/docs/en/hooks
# matcher: "Edit|Write|MultiEdit" 限定で settings.json から登録
# （Codex の hooks.json にも同じ定義が入る。Codex では Edit / Write の matcher が apply_patch にも当たる）
#
# 検査仕様は shared/skills/_template/reference/skill-frontmatter-spec.md を参照
# - 必須フィールド欠落 → permissionDecision: "deny" でファイル書き込みを阻止
# - トリガー語不足 → permissionDecision: "ask" で人間判断（Codex は ask に未対応なので deny に変える）
# - 検査対象外 (非 SKILL.md / _*/SKILL.md) → exit 0 で素通し
# - Codex の apply_patch: patch を解釈して対象の SKILL.md ごとに同じ検査を当てる（lint_apply_patch）
#
# NOTE: 機微情報を扱う場合は CLAUDE.md:L28-L46 の env-var indirection を参照
# NOTE: MultiEdit パースは Python フォールバックで多行/特殊文字を安全に扱う (W-B 対応)

set -euo pipefail

INPUT=$(cat)
# 前処理のエラーは実行ごとの一時ファイルに書く（固定パスだと、並行して走る別の hook の失敗の理由を出す）。
# trap の中のコマンドは失敗させない。失敗すると終了コードが変わり、出力済みの判定が無効になる
ERR_FILE=""
trap 'if [[ -n "$ERR_FILE" ]]; then rm -f "$ERR_FILE" 2>/dev/null || true; fi' EXIT
ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/skill-lint-err.XXXXXX" 2>/dev/null) || ERR_FILE=""
# malformed JSON は silent miss を生むため非ゼロ終了して可観測化
# オブジェクトでない入力（配列・tool_input が false 等）も止める。jq -e . は通し、後続の jq が exit 5 で落ちて素通しする
if ! echo "$INPUT" | jq -e 'type == "object" and ((.tool_input | type) | . == "object" or . == "null")' >/dev/null 2>&1; then
  echo "$(basename "$0"): malformed input JSON" >&2
  exit 2
fi
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')

# Codex は permissionDecision: "ask"（確認プロンプト）に未対応で、未対応の値は hook の失敗として
# 扱われ、操作が続行する（= ガードが黙って開く）。Codex の PreToolUse 入力は turn_id を持つ
# （Claude Code の入力には無い）ので、それで見分けて ask を deny に変え、確認をユーザーに戻す。
# 共通ファイルを source しない: source が失敗すると exit コードが 2 以外になり、ガードが黙って開く。
# 同じ関数を ask を返す hook に複製し、verify-skills.sh の対称性 check が存在を確かめる
decide_ask_or_deny() {  # $1=理由, $2=Codex で止めたときの次の行動（省略可）
  local decision="ask" reason="$1"
  if echo "$INPUT" | jq -e 'has("turn_id")' >/dev/null 2>&1; then
    decision="deny"
    reason="[要確認] ${reason} — Codex は確認プロンプトに未対応のため止めました。${2:-ユーザーに確認し、ユーザー自身に実行してもらってください。}"
  fi
  # trace に実際の判定を記録するため（Codex では deny）
  LAST_DECISION="$decision"
  jq -n --arg decision "$decision" --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: $decision,
      permissionDecisionReason: $reason
    }
  }'
}

lint_content() {  # 環境変数 CONTENT（検査する本文）を検査し、問題があれば ask / deny の JSON を出す。
  # 素通しも含め途中で exit 0 するので、複数の本文を検査する呼び出し側はサブシェル $(...) で呼ぶ
if [[ -z "$CONTENT" ]]; then
  exit 0
fi

# 3. frontmatter ブロックを抽出 (--- で囲まれた YAML)。pipe にしない。awk が早く exit すると書き手が
#    SIGPIPE で落ち、set -e で hook ごと終わる（判定が出ずに素通しになる）
FRONTMATTER=$(awk '
  /^---$/ { c++; if (c==1) { in_fm=1; next } else if (c==2) { exit } }
  in_fm { print }
' <<<"$CONTENT")

if [[ -z "$FRONTMATTER" ]]; then
  # frontmatter が無い SKILL.md は不正だが、新規作成途中の可能性もある → ask
  decide_ask_or_deny "SKILL.md に YAML frontmatter (--- で囲まれたブロック) が見つかりません。新規作成途中であれば続行してください。詳細は shared/skills/_template/reference/skill-frontmatter-spec.md を参照。" \
    "frontmatter を付けた内容で編集し直してください。"
  exit 0
fi

# 4. 必須フィールドの存在チェック
HAS_NAME=$(echo "$FRONTMATTER" | grep -cE '^name:' || true)
HAS_DESC=$(echo "$FRONTMATTER" | grep -cE '^description:' || true)

if [[ "$HAS_NAME" -eq 0 ]] || [[ "$HAS_DESC" -eq 0 ]]; then
  MISSING=""
  [[ "$HAS_NAME" -eq 0 ]] && MISSING="${MISSING}name "
  [[ "$HAS_DESC" -eq 0 ]] && MISSING="${MISSING}description "
  MISSING=$(echo "$MISSING" | sed 's/ $//')

  jq -n --arg missing "$MISSING" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("SKILL.md frontmatter に必須フィールド (" + $missing + ") が欠落しています。詳細は shared/skills/_template/reference/skill-frontmatter-spec.md を参照。")
    }
  }'
  exit 0
fi

# 5. description 値の抽出 (多行 YAML 対応: description: | や > も含めて次の key 行直前まで)
# pipe にしない（上の FRONTMATTER と同じ理由。閉じの --- が無いと FRONTMATTER がファイルの残り全体になる）
DESC_VALUE=$(awk '
  /^description:/ { in_desc=1 }
  in_desc && /^[a-zA-Z_-]+:/ && !/^description:/ { exit }
  in_desc { print }
' <<<"$FRONTMATTER")

# 6. トリガー語の存在チェック (連語化、単一文字を回避、case-insensitive)
#
# disable-model-invocation: true の skill は description が listing に載らず Claude からも
# 起動されないため、トリガー語 (Claude の自動選択精度を上げるための記述) を強制しない。
# 強制すると、誰も読まない死んだ指示を書かせ続けることになる。
# skillOverrides (settings.json 側) は見ない — name-only の skill は listing に名前が載って
# Claude から起動されうるため、トリガー語は依然として意味を持つ。
if echo "$FRONTMATTER" | grep -qE '^disable-model-invocation:[[:space:]]*true'; then
  exit 0
fi

TRIGGER_REGEX='時に|する時|使用|呼び出|キーワード|トリガー|when |trigger|use this|use when'

if ! echo "$DESC_VALUE" | grep -qiE "$TRIGGER_REGEX"; then
  decide_ask_or_deny "SKILL.md description にトリガー語 (時に / する時 / 使用 / 呼び出 / キーワード / トリガー / when / trigger / use this / use when) が含まれていません。Claude の skill 自動選択精度に影響します。承認して保存しますか?" \
    "トリガー語を足して編集し直すか、このままでよいかユーザーに確認してください。このままでよければ、ユーザー自身に保存してもらってください。"
  # opt-in trace: CLAUDE_CODE_HOOK_TRACE 環境変数が定義されている時のみログ出力
  if [[ -n "${CLAUDE_CODE_HOOK_TRACE:-}" ]]; then
    mkdir -p ~/.claude/logs
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $(basename "$0") matched=true decision=${LAST_DECISION:-ask} reason=trigger-missing" >> ~/.claude/logs/hook-trace.log
  fi
  exit 0
fi

# すべての検査をパス → exit 0 (素通し)
exit 0
}

# apply_patch（Codex）。SKILL.md の編集は Write / Edit ではなく apply_patch で行われる。入力には
# tool_input.file_path が無く（patch 本文は tool_input.command）、下の file_path による早期 return を
# 通すと必ず素通りして、Codex 側の lint が黙って開く。そのため、この分岐は早期 return より前に置く。
#
# patch の書式は Codex 0.160.0 に同梱された apply_patch の文法に従う:
#   *** Begin Patch / [*** Environment ID: <id>] / hunk+ / *** End Patch
#   hunk = Add File（+ 行）/ Delete File / Update File [*** Move to:]（@@ と ' ' '-' '+' の行。
#          先頭の hunk だけ @@ を省略できる）[*** End of File]
# patch の解釈と現ファイルへの適用は python で行い、対象の SKILL.md ごとの検査後の本文を JSON で返す。
# 検査（lint_content）は Write / Edit / MultiEdit と共通で、組み立て方だけが分岐する
lint_apply_patch() {
  local patch cwd results fatal item path err content out
  patch=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
  cwd=$(echo "$INPUT" | jq -r '.cwd // ""')

  # quote 付き heredoc + 環境変数渡しで bash 変数展開を抑止する。python が起動できない・落ちた場合も
  # fatal として扱う（黙って素通しにしない）
  if ! results=$(PATCH="$patch" PATCH_CWD="$cwd" python3 - <<'PY' 2>"${ERR_FILE:-/dev/null}"
import json, os, re

class PatchError(Exception):
    pass

patch = os.environ["PATCH"]
cwd = os.environ.get("PATCH_CWD", "")


# 見出しの規則は Codex 0.160.0 の apply_patch パーサに合わせる（見出しは前後を trim・パス先頭の空白は保持・
# Update の本文中の ' ***' は文脈行・End of File は末尾の空白だけ無視）。実パーサとずれると、SKILL.md への
# 書き込みを検査せずに通す。Python の strip() は Rust の trim() より多くの空白を落とすので、ずれは検査しすぎる側に倒れる
def parse(text):
    lines = [l.rstrip("\r") for l in text.strip().split("\n")]
    # シェルの heredoc で包んだ patch（<<EOF・<<'EOF'・<<"EOF" … EOF）は実パーサが外して適用する
    if len(lines) >= 4 and lines[0] in ("<<EOF", "<<'EOF'", '<<"EOF"') and lines[-1].endswith("EOF"):
        lines = lines[1:-1]
    if not lines or lines[0].strip() != "*** Begin Patch":
        raise PatchError("先頭の行が *** Begin Patch ではありません")
    if lines[-1].strip() == "*** End Patch":
        lines[-1] = "*** End Patch"
    i = 1
    if i < len(lines) and lines[i].strip().startswith("*** Environment ID: "):
        i += 1
    ops = []
    cur = None
    ended = False
    for line in lines[i:]:
        # 途中の終わりは rstrip のまま判定する。strip にすると Update の文脈行 ' *** End Patch' で打ち切り、
        # 後ろの hunk を取りこぼす
        if line.rstrip() == "*** End Patch":
            ended = True
            break
        in_update = cur is not None and cur["op"] == "update"
        head = line.rstrip() if in_update else line.strip()
        if head.startswith("*** Add File: "):
            cur = {"op": "add", "path": head[len("*** Add File: "):], "move": None, "body": []}
            ops.append(cur)
        elif head.startswith("*** Delete File: "):
            cur = {"op": "delete", "path": head[len("*** Delete File: "):], "move": None, "body": []}
            ops.append(cur)
        elif head.startswith("*** Update File: "):
            cur = {"op": "update", "path": head[len("*** Update File: "):], "move": None, "body": []}
            ops.append(cur)
        elif line.startswith("*** Move to: ") and in_update and not cur["body"]:
            cur["move"] = line[len("*** Move to: "):].rstrip()
        elif cur is None:
            raise PatchError("ファイルの見出しより前に本文があります: %r" % line[:40])
        else:
            cur["body"].append(line)
    if not ended:
        raise PatchError("末尾の行が *** End Patch ではありません")
    return ops


def seek(lines, pat, start, eof):
    """pat と一致する連続した行の先頭位置。厳密 → 行末の空白を無視 → 前後の空白を無視の順に探す"""
    n = len(pat)
    first = max(start, len(lines) - n) if eof else start
    for norm in (lambda s: s, lambda s: s.rstrip(), lambda s: s.strip()):
        for i in range(first, len(lines) - n + 1):
            if all(norm(lines[i + k]) == norm(pat[k]) for k in range(n)):
                return i
    return None


def apply_update(path, body, text):
    hunks = []
    cur = None
    for l in body:
        if l.startswith("@@"):
            if cur is not None:
                hunks.append(cur)
            ctx = l[3:].strip() if l.startswith("@@ ") else ""
            cur = {"ctx": ctx, "old": [], "new": [], "eof": False}
            continue
        if cur is None:
            cur = {"ctx": "", "old": [], "new": [], "eof": False}
        if l.rstrip() == "*** End of File":
            cur["eof"] = True
        elif l == "":
            cur["old"].append("")
            cur["new"].append("")
        elif l[0] == " ":
            cur["old"].append(l[1:])
            cur["new"].append(l[1:])
        elif l[0] == "-":
            cur["old"].append(l[1:])
        elif l[0] == "+":
            cur["new"].append(l[1:])
        else:
            raise PatchError("Update の hunk に解釈できない行があります: %r" % l[:40])
    if cur is not None:
        hunks.append(cur)
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    pos = 0
    for h in hunks:
        if h["ctx"]:
            hit = seek(lines, [h["ctx"]], pos, False)
            if hit is None:
                raise PatchError("%s: @@ の文脈の行が現ファイルに見つかりません: %r" % (path, h["ctx"][:60]))
            pos = hit + 1
        if not h["old"]:
            lines.extend(h["new"])
            pos = len(lines)
            continue
        hit = seek(lines, h["old"], pos, h["eof"])
        if hit is None:
            raise PatchError("%s: hunk の旧テキストが現ファイルに見つかりません: %r" % (path, h["old"][0][:60]))
        lines[hit:hit + len(h["old"])] = h["new"]
        pos = hit + len(h["new"])
    return "\n".join(lines) + "\n"


def build(op):
    if op["op"] == "add":
        for l in op["body"]:
            if not l.startswith("+"):
                raise PatchError("Add File の本文に + で始まらない行があります: %r" % l[:40])
        return "\n".join(l[1:] for l in op["body"]) + "\n"
    src = op["path"]
    if not src.startswith("/"):
        if not cwd:
            raise PatchError("入力に cwd が無いため、相対パスの現ファイルを読めません: %s" % src)
        src = os.path.join(cwd, src)
    try:
        with open(src, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError as e:
        raise PatchError("現ファイルを読めません: %s" % e)
    return apply_update(op["path"], op["body"], text)


try:
    results = []
    for op in parse(patch):
        if op["op"] == "delete":
            continue
        eff = op["move"] or op["path"]
        full = eff if eff.startswith("/") else "/" + eff
        # 相対パスの skills/x/SKILL.md が /SKILL.md$ に当たるよう、先頭に / を補ってから判定する。
        # macOS の APFS は大文字小文字を区別しないので、skill.md 指定でも SKILL.md が書き換わる
        if not re.search(r"/SKILL\.md$", full, re.IGNORECASE) or re.search(r"/_[^/]+/SKILL\.md$", full, re.IGNORECASE):
            continue
        try:
            results.append({"path": eff, "content": build(op)})
        except PatchError as e:
            results.append({"path": eff, "error": str(e)})
    print(json.dumps(results, ensure_ascii=False))
except Exception as e:
    print(json.dumps({"fatal": str(e)}, ensure_ascii=False))
PY
  ); then
    results=$(jq -nc --arg e "$(cat "${ERR_FILE:-/dev/null}" 2>/dev/null)" '{fatal: ("python が失敗しました: " + $e)}')
  fi

  # 解釈できない patch。SKILL.md に触れている疑いがあれば止める（確認に委ねる）。無関係なら通す。
  # 全 patch を止めると、文法が将来変わったときに Codex の編集がすべて止まる
  fatal=$(echo "$results" | jq -r 'if type == "object" then .fatal // "" else "" end')
  if [[ -n "$fatal" ]]; then
    if [[ "$(printf '%s' "$patch" | LC_ALL=C tr 'A-Z' 'a-z')" == *skill.md* ]]; then
      decide_ask_or_deny "SKILL.md lint の前処理に失敗しました: ${fatal} — 内容を目視確認して承認してください。"
    fi
    exit 0
  fi

  # 対象の SKILL.md ごとに検査する。lint_content は途中で exit 0 するので、サブシェルで呼ぶ
  # （ループ全体が 1 件目で終わらないように）。問題があれば最初の 1 件で止める
  while IFS= read -r item; do
    path=$(echo "$item" | jq -r '.path')
    err=$(echo "$item" | jq -r '.error // ""')
    if [[ -n "$err" ]]; then
      decide_ask_or_deny "SKILL.md lint の前処理に失敗しました (${path}): ${err} — 内容を目視確認して承認してください。"
      exit 0
    fi
    content=$(echo "$item" | jq -r '.content // ""')
    # 本文を環境変数として子プロセスに渡さない（1 MB を超えると awk の起動が Argument list too long で落ちる）
    out=$(CONTENT=$content; lint_content)
    if [[ -n "$out" ]]; then
      # 複数ファイルの patch で、どの SKILL.md が問題か分かるように理由にパスを足す
      echo "$out" | jq --arg f "$path" '.hookSpecificOutput.permissionDecisionReason |= ("[" + $f + "] " + .)'
      exit 0
    fi
  done < <(echo "$results" | jq -c '.[]')
  exit 0
}

if [[ "$TOOL_NAME" == "apply_patch" ]]; then
  lint_apply_patch
fi

# 1. 検査対象判定: SKILL.md でなければ素通し。macOS の APFS は大文字小文字を区別しないので、skill.md 指定でも
#    SKILL.md が書き換わる。小文字にそろえて比べる（bash 3.2 に ${v,,} は無い。LC_ALL=C は、不正な UTF-8 で
#    tr が落ちて素通しになるのを避けるため）
FILE_PATH_LC=$(printf '%s' "$FILE_PATH" | LC_ALL=C tr 'A-Z' 'a-z')
if [[ ! "$FILE_PATH_LC" =~ /skill\.md$ ]]; then
  exit 0
fi

# _ プレフィックスディレクトリは除外 (_template, _example 等)
if [[ "$FILE_PATH_LC" =~ /_[^/]+/skill\.md$ ]]; then
  exit 0
fi

# 2. 検査対象テキストの構築 (Write / Edit / MultiEdit)
CONTENT=""
case "$TOOL_NAME" in
  Write)
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // ""')
    ;;
  Edit)
    OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // ""')
    NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // ""')
    # replace_all のときは全置換する。1 回だけ置換して検査すると、全置換で消えるフィールドを見落とす
    REPLACE_ALL=$(echo "$INPUT" | jq -r 'if .tool_input.replace_all == true then 1 else 0 end')
    if [[ ! -f "$FILE_PATH" ]]; then
      # 既存ファイルが無い場合は素通し（Edit は通常存在前提）
      exit 0
    fi
    # quote 付き heredoc + 環境変数渡しで bash 変数展開を抑止 (injection 経路を遮断)
    # 失敗時は permissionDecision: ask で明示的にユーザーへ通知（silent abort を防ぐ）
    if ! CONTENT=$(FILE_PATH="$FILE_PATH" OLD="$OLD" NEW="$NEW" REPLACE_ALL="$REPLACE_ALL" python3 - <<'PY' 2>"${ERR_FILE:-/dev/null}"
import os, sys
try:
    with open(os.environ["FILE_PATH"], encoding="utf-8", errors="replace") as f:
        content = f.read()
    count = -1 if os.environ["REPLACE_ALL"] == "1" else 1
    content = content.replace(os.environ["OLD"], os.environ["NEW"], count)
    sys.stdout.write(content)
except Exception as e:
    sys.stderr.write(f"lint-prep-failed: {e}\n")
    sys.exit(2)
PY
    ); then
      decide_ask_or_deny "SKILL.md lint の前処理に失敗しました: $(cat "${ERR_FILE:-/dev/null}" 2>/dev/null) — 内容を目視確認して承認してください。"
      exit 0
    fi
    ;;
  MultiEdit)
    if [[ ! -f "$FILE_PATH" ]]; then
      exit 0
    fi
    EDITS_JSON=$(echo "$INPUT" | jq -c '.tool_input.edits // []')
    # quote 付き heredoc + 環境変数渡しで bash 変数展開を抑止
    if ! CONTENT=$(FILE_PATH="$FILE_PATH" EDITS_JSON="$EDITS_JSON" python3 - <<'PY' 2>"${ERR_FILE:-/dev/null}"
import json, os, sys
try:
    with open(os.environ["FILE_PATH"], encoding="utf-8", errors="replace") as f:
        content = f.read()
    edits = json.loads(os.environ["EDITS_JSON"])
    for e in edits:
        count = -1 if e.get("replace_all") is True else 1
        content = content.replace(e.get("old_string", ""), e.get("new_string", ""), count)
    sys.stdout.write(content)
except Exception as e:
    sys.stderr.write(f"lint-prep-failed: {e}\n")
    sys.exit(2)
PY
    ); then
      decide_ask_or_deny "SKILL.md lint の前処理に失敗しました: $(cat "${ERR_FILE:-/dev/null}" 2>/dev/null) — 内容を目視確認して承認してください。"
      exit 0
    fi
    ;;
  *)
    exit 0
    ;;
esac

# 検査本体。Write / Edit / MultiEdit はここで 1 回だけ呼ぶ（apply_patch は上の分岐で対象ごとに呼ぶ）
lint_content
