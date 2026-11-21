#!/usr/bin/env bash
# UserPromptSubmit hook: オーナーの聞き返し（「X-7って何？」「噛み砕いて」「次に何すればいい？」など）を検知し、
# 直前の説明の記号・略語の意味と現在地を添えて答え直す指示を additionalContext で足す。
# 説明の書き方の常設ルール（shared/global-rules.md の「説明の書き方」）が守られなかったときの保険。
# 公式: https://code.claude.com/docs/en/hooks
#
# ブロックはしない。UserPromptSubmit の exit 2 は発言の取り消しになるので、どの失敗でも exit 2 を返さない
# （不正な入力は exit 1 = non-blocking のエラーで見えるようにする）。
# NOTE: matcher なし (UserPromptSubmit は matcher 非対応)

set -uo pipefail

INPUT=$(cat)
if ! printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1; then
  echo "$(basename "$0"): malformed input JSON" >&2
  exit 1
fi
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // ""')

if [[ -z "$PROMPT" ]]; then
  exit 0
fi

# 照合から外すもの（オーナーの聞き返しではない部分）:
# - 通知（task-notification）・他セッションのメッセージ（agent-message）・貼り付け（pasted_content）の閉じたブロック
# - 閉じたコードブロック・インラインコード（ログやコードの中の「って何」に反応しない）
# - 行頭が > の引用行（AI の発言を引いて話題にしている）
# - 1 行の中の「」（「なんだっけ」のように語そのものを話題にしている。「受け口」って何？ は「」の外に語が残る）
# 閉じていないブロックは外さない（後ろを全部消して聞き返しを見落とすより、誤発火の方が軽い）。
# 除去に失敗したら元の文字列で照合する。bash の ${var//…/} は長い入力で数分かかるので使わない
MATCH_TEXT=$(printf '%s' "$PROMPT" | perl -0777 -pe '
  s/<task-notification>.*?<\/task-notification>//gs;
  s/<agent-message\b[^>]*>.*?<\/agent-message>//gs;
  s/<pasted_content\b[^>]*>.*?<\/pasted_content\b[^>]*>//gs;
  s/^[ \t]*```.*?^[ \t]*```[^\n]*$//gms;
  s/`[^`\n]*`//g;
  s/^[ \t]*>[^\n]*$//gm;
  s/「[^\n]*?」//g;
' 2>/dev/null) || MATCH_TEXT="$PROMPT"

# 聞き返しの語。短い語（「何」「つまり」）だけでは判定せず、連語か疑問符つきで要求する:
# - X って何 / ってなに / ってなん + 疑問符・だっけ・です・を指す・を意味する・行末（「ってなんで」= 理由の質問は外す）
# - なんだっけ・何だっけ / どういう意味・どういうこと / 噛み砕いて（表記ゆれ）/ つまり？ / X とは？
# - よく・いまいち・全然 + わからない / わかりにくい・わかりづらい
# - 何（を）すればいい / どうすればいい
# 多バイト文字は [] に入れない（ロケールが C のとき 1 バイトずつの選択肢になる）
TRIGGER_REGEX='って(何|なに|なん)(\?|？|だっけ|です|を指|を意味|$)|(何|なに|なん)だっけ|どういう(意味|こと)|噛み砕|かみ砕|噛みくだ|かみくだ|つまり(\?|？)|とは(\?|？)|(よく|いまいち|全然|ぜんぜん)(わ|分)から(ない|ん)|(わ|分)かり(にく|づら)い|(何|なに)(を)?すれば(いい|良い|よい)|どうすれば(いい|良い|よい)'

# hook-block-tmp-commit.sh の matches() の複製。echo | grep -q は、grep が最初のマッチで終わると書き手が
# SIGPIPE で死に、pipefail で照合が偽になる（約 64KB を超える入力で、前半の聞き返しを見落とす）。
# grep -c は入力を読み切るので SIGPIPE が起きない
matches() {  # $1=入力, $2=拡張正規表現
  [[ "$(printf '%s\n' "$1" | grep -cE "$2" || true)" -gt 0 ]]
}

if matches "$MATCH_TEXT" "$TRIGGER_REGEX"; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "🧭 [聞き返しの可能性] オーナーが直前の説明を問い直している可能性がある。そうなら次の順で答え直す: (1) 要するに 1 文 (2) 問われた記号・略語と、直前の発言に出た記号・略語・ラベルの意味（各 10 字程度。前に説明したかで省かない）(3) 判断待ちがあれば 1 件ずつ自己完結（何の話・選択肢・推奨を先頭・選ぶと何が起きるか）(4) 最後に現在地（動いている作業・待っている判断・次にやること）。直前の説明と関係の無い質問なら、この指示は無視して普通に答える。"
  }
}
EOF
  # opt-in trace: CLAUDE_CODE_HOOK_TRACE 環境変数が定義されている時のみログ出力（失敗しても hook は終わらせない）
  if [[ -n "${CLAUDE_CODE_HOOK_TRACE:-}" ]]; then
    { mkdir -p ~/.claude/logs && echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $(basename "$0") matched=true" >> ~/.claude/logs/hook-trace.log; } 2>/dev/null || true
  fi
fi

exit 0
