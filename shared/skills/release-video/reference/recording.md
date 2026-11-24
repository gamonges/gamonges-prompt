# 撮影（record 段）の手順

場面ごとの 1920×1080 の録画を、ブラウザ（playwright-cli）で撮る手順。場面・URL・セレクタは対象のプロダクトごとに違うので、撮影の実行用スクリプト（`rec.sh`）は補助スクリプトにせず、**骨格を手順に書き、実行時に `tmp/release-video/rec.sh` へ生成する**。

`S=~/.claude/skills/release-video/scripts`（install 後。この repo の worktree では `shared/skills/release-video/scripts`）。

## 1. 依存の確認

`command -v playwright-cli ffmpeg ffprobe`。無いものは**案内だけして止める**（導入は利用者が行うか、利用者の了承の後）。skill が勝手にインストール・ダウンロードしない。

## 2. 確かめた版と現行の挙動

確かめた版: **playwright-cli 0.1.17**（`playwright-cli <command> --help` で確認）。版が変わったら、ここを見直す。

- 既定は headless。**録画（`video-start`）は headless だと 0 バイトのファイルしかできない**ので、録画する session は `open --headed` で開く。headed のウィンドウは 1920×1080 より小さいので、`video-start` の前に `resize 1920 1080` を行う（行わないと、画面が左上に寄って残りが灰色になる）。スクリーンショットだけなら headless でよい
- `video-start [filename] --size=1920x1080`。`--size` を省くと 800x800 に収まる大きさになる
- `video-stop` は**引数なし**（`video-stop <file>` と書いた古い記述がある）
- ファイル名は**呼び出し元の cwd**から解決される。`rec.sh` は絶対パスで渡す
- `file:` のページは既定で開けない（スクリーンショットも白紙になる）。`python3 -m http.server --bind 127.0.0.1 --directory <dir> <port>` で配り、`http://127.0.0.1:<port>/` で開く
- 重ね表示の注入は `run-code` で `page.context().addInitScript({path: <overlay.js の絶対パスの JSON 文字列>})`（以後に開く全ページに入る）。パスは `scenes.py session` の出力で埋める（作業ディレクトリのパスに `'`・`"`・空白があっても JS の文字列として壊れない）
- `addInitScript({path})` は**呼んだ時点で**ファイルを読み、その中身を送る（playwright-cli 0.1.17 に同梱の playwright-core 1.62.0-alpha の `lib/coreBundle.js` の `evaluationScript`）。登録の後に overlay.js を書き換えても、ブラウザの overlay は変わらない
- overlay は読み込んだ時点の設定を取り込み、2 回目に読み込まれても初期化し直さない（`overlay-template.js` の `if (window.__ov) return;`）。同じ session に登録し直すと、**先に登録した古い overlay が勝つ**。overlay を作り直したら session を開き直す（節 4）
- 未起動の session への操作は拒否される。先に `open` する

## 3. 専用 ffmpeg が無いとき

`video-start` が `Executable doesn't exist at <path>` で失敗する。置き場所はそのエラーの `<path>` から読む（revision を本文に決め打ちしない）。選択肢を示して、**利用者に選んでもらう**（どちらも了承の後に行う）:

- (a) `npx playwright install ffmpeg`（ダウンロード）
- (b) 手元の ffmpeg（`command -v ffmpeg` の結果）へのリンクを、エラーの `<path>` に張る。非公式の代用で、Playwright が出力を保証するかは未確認

## 4. 撮影用の session を開く

overlay は、ログインの前に、撮影に使う session へ 1 回だけ登録する（ログインは同じ session で行うので、後から開き直すとログインし直しになる）。

1. `python3 $S/render.py overlay --dir <dir>` で `overlay.js` を作る（`blur_patterns` の検証が通らなければ止める）
2. `ov="$(python3 $S/scenes.py session --dir <dir>)"`。`overlay.js` が今の設定と同じかを確かめ、`clips/session.json` に印を書き、`overlay.js` の絶対パスの JSON 文字列を 1 行で出す。exit 1 なら止める
3. `playwright-cli -s=<session> close`（残っている session を閉じる。未起動なら拒否されるだけで、失敗してよい）
4. `playwright-cli -s=<session> open --headed` → `playwright-cli -s=<session> resize 1920 1080`
5. `playwright-cli -s=<session> run-code "async page => { await page.context().addInitScript({path: $ov}); }"`。失敗したら止める

`scenes.py begin`（record）は、`clips/session.json` の印が今の期待値と違えば止まる（「撮影用の session を開き直す」）。session を開いた後に設定を変えて overlay を作り直したとき、ブラウザの古い overlay のまま録画しないため。overlay を作り直したら（`badpattern` の修正など）、この節からやり直し、利用者にログインし直してもらう。

## 5. ログイン

前の節で開いた session の画面で、**利用者が自分でログインする**。Claude はパスワード・ワンタイムコードを入力しない。組織・テナントの切り替えも利用者に頼む。ログイン後に、利用者から「できた」と聞いてから先へ進む。

## 6. 撮影データの確認（読むだけ）

台本の「撮影の前に確かめること」を、各場面の画面を開いて snapshot で確かめる（見せたい画面に中身があるか。QA の後片付けで消えていることがある）。DB の照会が遅い・止まるときは、画面での確認に切り替える。

## 7. 書き込みの規律

既定は**読むだけ**。書き込みが要るときだけ:

1. 画面・項目・元の値・撮影用の値を示して、**毎回**利用者の確認を取る
2. `data-changes.md` に控えてから保存する（下の雛形）
3. 「元に戻せない設定」（未設定に戻す手段が無い等）は、保存の前に相談する
4. 撮影の後に元の値へ戻し、画面を読み直して戻ったことを確かめ、控えの「戻した日時」「戻したことの確認」を埋める

「戻した日時」が空の行が残る間は、`scenes.py status` が record を `restore`（「撮影用データを戻していない: <画面>・<項目>」）にして done にせず、compose へ進まない。中断して再開したときに、戻し忘れへ戻れるようにするため。書き込みの了承が無いときは、読むだけで撮れる見せ方を相談する。

`data-changes.md` の雛形（`tmp-frontmatter` の目印は**行頭**に置き、次の行をフェンスの開始にする。字下げすると test-knowledge.sh が目印を拾わない）:

<!-- tmp-frontmatter: tmp/release-video/data-changes.md -->
```markdown
---
type: Video Data Log
title: <機能名>の撮影用データの控え
description: 撮影のために書き込んだ値と、元に戻した記録
status: draft
---
# 撮影用データの控え

| # | 画面 | 項目 | 元の値 | 撮影用の値 | 確認を取った日時 | 戻した日時 | 戻したことの確認 |
|---|------|------|--------|-----------|------------------|-----------|------------------|
```

## 8. 場面の骨格（rec.sh の生成）

1. 撮影用の session（節 4）を開いてログインしてから、`scenes.json` の `kind: record` から `tmp/release-video/rec.sh` を生成する。冒頭で作業ディレクトリを絶対パスに解決して（`DIR="$(cd <dir> && pwd)"`）`cd "$DIR"` し、playwright-cli に渡すファイル名はすべて `"$DIR/…"` の絶対パスにする（snapshot などの自動の出力 `.playwright-cli/` も作業ディレクトリの中にできる）
2. rec.sh は場面だけを撮る（`open`・overlay の登録・`close` をしない）。冒頭で全場面の `scenes.py begin --stage record` を通す（古い clip と `.events` を消し、作る直前の入力を控える。撮影用の session の印も照合する）。1 つでも止まったら撮らない
3. ヘルパー（`-s=<session>` 付きの呼び出し・`eval`・snapshot から ref を引く）は、zsh の未クォート展開の癖を避けるため配列で渡す
4. 各場面の骨格: 移動 → 読み込み待ち → `video-start "$DIR/clips/<id>.webm" --size=1920x1080` → `telop`・`hl`（操作のたびに、録画の開始からの秒を `clips/<id>.events` に 1 行書く）→ 音声の長さ（audio の manifest の `duration`。`narr` が空なら `seconds`）だけ待つ → `video-stop`
5. **`scenes.py mark` はここでは打たない**（次の節の確認の後）

```bash
#!/bin/zsh
set -u
DIR="$(cd "<作業ディレクトリ>" && pwd)"; cd "$DIR"
SESSION="<session 名>"
pc() { playwright-cli "-s=$SESSION" "$@" 2>&1 }
ev() { playwright-cli "-s=$SESSION" eval "$1" 2>&1 }
S="<補助スクリプトの絶対パス>"
mkdir -p "$DIR/clips"
for id in <record の id …>; do python3 "$S/scenes.py" begin --dir "$DIR" --stage record --id "$id" || exit 1; done

scene_<id>() {
  pc resize 1920 1080 >/dev/null
  pc goto "<url>" >/dev/null; sleep 4
  pc video-start "$DIR/clips/<id>.webm" --size=1920x1080; T0=$SECONDS
  ev "window.__ov.telop('<テロップ>')"; echo "$((SECONDS - T0)) telop" >> "$DIR/clips/<id>.events"
  ev "window.__ov.hl('<セレクタか文字列>')"; echo "$((SECONDS - T0)) hl" >> "$DIR/clips/<id>.events"
  sleep <音声の長さ>
  pc video-stop
}
```

## 9. 録画の後の確認（mark の前）

1. `window.__ov.log` を読む（`ev` ではなく `playwright-cli eval` の出力で）。`badpattern` が 1 件でもあれば、その録画を使わない（式を直して `overlay.js` を作り直し、撮影用の session を開き直して（節 4）録り直す）。`notfound` は節 10 へ
2. 各クリップから、先頭・`<id>.events` の各時刻の 0.2 秒後と 1 秒後・中ほど・末尾のコマを `ffmpeg -ss <秒> -i "$DIR/clips/<id>.webm" -frames:v 1 <png>` で取り出して Read し、ぼかし・テロップ・強調枠を確かめる
3. 個人情報（メールアドレス・人名）が見えたら、設定の `blur_patterns` に足して録り直す。漏れうる画面（一覧の書き換えが速い等）は、個人情報の出ない撮影用のデータか別の画面で見せる
4. 録画が終わったら `playwright-cli -s=<session> close` で session を閉じる
5. すべて問題が無いクリップだけを `python3 $S/scenes.py mark --dir <dir> --stage record --id <id>` で記録する（録画の長さ・中身の sha が manifest に入る）。mark は begin を通した素材だけを受け付け、begin の控え（`clips/<id>.meta`）と今の入力、`overlay.js` と今の設定を照合する。成功すると控えを消すので、撮り直しは begin からやり直す。rec.sh の実行中に `overlay.js` を作り直さない

## 10. 詰まったとき

要素が見つからない場面（`notfound`）は深追いせず、場面の見せ方（別の画面・別の強調）を利用者と決め直す。決め直した結果が台本の変更になるなら、`scenes.json` を直して `table` → 再承認（`SKILL.md`）。
