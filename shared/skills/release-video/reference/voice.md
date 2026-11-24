# 声（voice 段）

ナレーションの声を選び、規約を利用者に確かめ、合成して尺を測る手順。**skill は既定の声を持たず、特定の声を勧めない**。声の選択と規約の当否の判断は利用者のもの。

`S=~/.claude/skills/release-video/scripts`（install 後。この repo の worktree では `shared/skills/release-video/scripts`）。どのコマンドも `--dir`（既定 `./tmp/release-video`）を取る。

## 手順

1. **声の候補を出して、利用者に選んでもらう**
   - macOS の `say`: `say -v '?'`（日本語は `ja_JP`）。`voice.py trial` は `--say-voice` を付けなければ `-v` を付けず、OS の既定の声で試し読みする
   - VOICEVOX（ローカルのエンジン。既定 `http://127.0.0.1:50021`）: `python3 $S/voice.py speakers --engine voicevox [--engine-url <URL>]`。出力は `名前⇥speaker_uuid⇥スタイル名⇥style id`
   - エンジンが動いていなければ、起動を利用者に頼む（導入・起動は skill が勝手にしない）
2. **規約を利用者に確かめてもらう**（Claude は商用に当たるかを判断しない）
   - VOICEVOX: `python3 $S/voice.py policy --engine voicevox --speaker-uuid <uuid>` の文面を**そのまま**見せる
   - `say`: OS の使用許諾が適用されると伝え、利用者に確かめてもらう
   - どちらも「今回の用途（社内・社外・有償）」「商用の扱い」「クレジットの要否と表記」を利用者に答えてもらう。規約が「商用は事前確認」などで利用者が決めきれないときは、別の声に替えるか、権利者に確かめてから進むかを聞く
3. **voice.json に記録する**（形は下記）。`confirmed_by_user: true` は、利用者が自分で確かめたと答えたときだけ書く。`terms.credit_required` が `true` なのに `credit` が空なら、合成は exit 1 で止まる
4. **読みを確認する**: `python3 $S/voice.py reading --dir <dir>` の出力（シーンごとの読み上げ用の文）を見せ、略語・英字・数字の読みを利用者に聞く。置き換えは設定の `reading.replacements`（`profile.md`）か、シーンの `narr_reading`（書いた読みは整形を当てずそのまま使う）に入れる。数字の読みを自動では変えない
5. **合成**: `python3 $S/voice.py synth --dir <dir> [--engine-url <URL>]` → `python3 $S/voice.py measure --dir <dir>`
6. **尺が超えたら**（`over:` の行）、次の順で詰める: `speed`（目安 1.2 まで）→ `pause_scale` → 台本の「尺が超えたら先に削る行」。台本を削ったら再承認が要る（`SKILL.md`）。VOICEVOX の `speed`・`pause_scale` を変えたら synth をやり直す（入力の sha が変わり voice が stale になる）

台本を書く段階の尺の見積もりは `voice.py trial`（say で試し読み → `trial/` と合計秒。say が無ければ文字数から 1 秒 6 字の推定で「推定」と表示）と `voice.py measure --trial` で行う。`trial/` の音声は公開しない。

## voice.json

```json
{
  "engine": "voicevox",
  "voice": "<声の名前（スタイル）>",
  "speaker": 0,
  "speaker_uuid": "<speaker_info の uuid。voicevox のとき必須>",
  "speed": 1.0,
  "pause_scale": 1.0,
  "credit": "<動画に載せるクレジット。不要と確かめたときだけ空>",
  "terms": {
    "source": "<規約の出どころ（エンジンの policy・配布元のページ・OS の使用許諾 など）>",
    "summary": "<利用者が確かめた要点（用途・商用の扱い・クレジット）>",
    "use": "<今回の用途（例: 社内の共有会で上映）>",
    "credit_required": true,
    "confirmed_by_user": true,
    "confirmed_on": "YYYY-MM-DD"
  }
}
```

- `engine`: `voicevox` か `say`。`say` のとき `speaker`・`speaker_uuid` は持たず、`voice` は `say -v` に渡す名前（`speed` は使われない）
- 既定値を持たないキー: `engine`・`voice`・`terms` の全部（声を skill が選ばないため）
- `credit` の正本はここだけ。カード（`render.py card`）が最後のカードに載せる

## 読み上げの整形（`voice.py reading`）

VOICEVOX は、半角空白・`「」`・英字の略語の手前で区切って余計な間を入れる。そのため `narr_reading` が無いシーンには次を当てる。

- `「」『』` を外す
- 日本語と英数字の間の半角空白を詰める（英字どうしの空白は残す）
- 設定の置き換え表を、長い `from` から当てる（`AB` と `ABC` があれば `ABC` が先）

`enable_katakana_english` は既定の `true` のままにする。読点の間は `pause_scale` で縮められる。

## 送信先の制限

`--engine-url` は `http` の loopback（`127.0.0.1`・`localhost`・`[::1]`）だけを許す（それ以外は exit 2）。環境変数のプロキシを使わず、リダイレクトにも追従しない（3xx は exit 3）。ナレーションに未公開の情報が入るため。
