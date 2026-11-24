---
name: release-video
description: 価値タスクからリリース共有用の 2 分以内のデモ動画（台本→声→撮影→カード→合成）を作る。段ごとに再開できる。`/release-video` 呼び出しで使用。
argument-hint: "<価値タスクの URL か本文> [--profile <file>] [--stage script|voice|record|cards|compose] [--dir <dir>]"
disable-model-invocation: true
---

価値タスク（機能の価値を書いたページや本文）から、文字のカード・画面録画・ナレーションでできた 1920×1080 の mp4（既定の上限は 2 分）を作る。台本の検証・承認・段の状態・カードと重ね表示・読み上げの整形と合成・ffmpeg の合成は補助スクリプト（python 標準ライブラリ）が行い、撮影と利用者との確認は本文の手順で行う。

出力先: `./tmp/release-video/`（ソースコードは変更しない。構成は `reference/script-format.md`）。会社・プロダクト固有の値（共有会の名前・配色・読みの置き換え・撮影先の起点）はこの skill のファイルに書かず、**設定ファイル**（`--profile <file>` か環境変数 `RELEASE_VIDEO_PROFILE`）から読む。最初に解決した設定は作業ディレクトリの `profile.json` に写され、以後の全コマンドが写しを使う。設定を直したら `--profile <file>` を付けて 1 回打ち直す（`reference/profile.md`）。

補助スクリプトは `S=~/.claude/skills/release-video/scripts`（Codex は `~/.agents/skills/release-video/scripts`。この repo の worktree では `shared/skills/release-video/scripts`）。どれも `--dir`・`--profile` を取り、exit は 0=成功 / 1=入力やデータの誤り / 2=引数の誤り / 3=外部コマンド・エンジンの失敗。

## 補助ドキュメントへの参照

**必ず読む**（起動したら必ず通る）:

| 補助ドキュメント | 読むタイミング |
|------------------|----------------|
| `./reference/script-format.md` | 台本を書く時・段の状態を読む時（scenes.json のスキーマ・時間割・script.md の雛形） |

**条件付きで読む**:

| 補助ドキュメント | 読むタイミング |
|------------------|----------------|
| `./reference/profile.md` | 設定ファイルを作る・直す時、設定の写しで迷った時 |
| `./reference/voice.md` | voice 段（声の選択・規約の確認・合成・尺の調整） |
| `./reference/recording.md` | record 段（撮影の手順・データの書き込みの規律） |

## 入口

1. 引数を解く。価値タスクは URL か本文。`--profile`・`--stage`・`--dir`（既定 `./tmp/release-video`）を読む
2. 作業ディレクトリが既にあれば、`python3 $S/scenes.py status --dir <dir>` を見せて、**再開 / 作り直し / キャンセル**を聞く。tmp/ の成果物を黙って上書きしない
   - 再開: `status` の最後の行 `next: <段>` から回す
   - 作り直し: `python3 $S/scenes.py rebuild --dir <dir>` で既存を `<dir>.bak-<日時>` へ退避してから script 段へ。戻していない撮影用データの控え（`data-changes.md`）があると exit 1 で止まるので、**先に戻す**（`reference/recording.md` の「書き込みの規律」の戻す手順）か、**控えを新しい作業ディレクトリに引き継ぐ**（`--carry`）かを利用者に選んでもらう。控えを黙って退避・削除しない
   - キャンセル: 何もしない
3. `--stage <段>` があれば、その段だけを回す。前の段が done でなければ `status` を見せて止める。無ければ `next:` の段から順に回す
4. 設定ファイルが無ければ、既定の段・配色・ぼかしで進め、台本の「条件」と報告に「設定なし（探した場所: …）」と書く

## 段の流れ

各段は、成果物の状態（`scenes.py status` の done / todo / stale / restore / over）で完了を判定する。

### script

1. 価値タスクを読む。URL は使える手段で読み、読めなければ本文の貼り付けを頼む（推測で埋めない）
2. `scenes.json` を書き（`reference/script-format.md`）、`python3 $S/scenes.py validate --dir <dir>` を通す。`script.md`（雛形は同ファイル）を作り、`python3 $S/scenes.py table --dir <dir>` で表を生成する
3. 要確認事項（本番の数値・人名・声の希望・読み）を利用者に聞く。確かめるまで仮の表現にする
4. 尺を測る: `python3 $S/voice.py trial --dir <dir>` → `python3 $S/voice.py measure --dir <dir> --trial`。収まらなければ「先に削る行」から削る
5. 利用者に台本を見せて**了承を得てから** `python3 $S/scenes.py approve --dir <dir>` を打つ（了承なしに打たない）
6. 承認の後に `scenes.json` を変えたら（voice 段で尺を詰めて削る場合も）、`table` → 前回の承認との差分を見せて再承認を取り、`approve` を打ち直す
7. 完了の報告で、台本を人が読めるよう `html-view` による HTML 化を 1 回だけ提案する

### voice

`reference/voice.md` の手順に従う（声は利用者が選ぶ・規約は利用者が確かめる・voice.json に記録 → `voice.py synth` → `voice.py measure`）。

### record

`reference/recording.md` の手順に従う（overlay → 撮影用の session を開く（`scenes.py session`）→ ログイン → rec.sh（全場面の `scenes.py begin` → 録画）→ 確認 → mark → 撮影用データを戻す）。

### cards

1. `python3 $S/render.py card --dir <dir>` で `cards/<id>.html` を作る。各カードの撮影の前に `python3 $S/scenes.py begin --dir <dir> --stage cards --id <id>` を通す（古い png を消し、作る直前の入力を控える）。begin の後に `render.py card` を流し直したら、その id は begin からやり直す（mark が html の違いで止まる）
2. `python3 -m http.server --bind 127.0.0.1 --directory <cards の絶対パス> <空いた port>` をバックグラウンドで起動する（`file:` では白紙になる）
3. `playwright-cli -s=<cards 用の session> open`（headless でよい。未起動の session への操作は拒否されるので先に開く）
4. `run-code` で `page.setViewportSize({width:1920,height:1080})`・`goto`・`screenshot({path: <png の絶対パスの JSON 文字列>})` を行う（パスは `p="$(python3 $S/render.py jstr "<cards の絶対パス>/<id>.png")" || 止める` で作ってから埋める。`'`・`"` を含むパスで壊れないため）。出力に `### Error` の見出しがあれば失敗として扱う（JS の例外は exit 0 で返る。`reference/recording.md` 節 2）
5. 撮った png を Read で確かめる（白紙でない・文字が切れていない）
6. 問題が無いカードだけ `python3 $S/scenes.py mark --dir <dir> --stage cards --id <id>` で記録する（begin を通した 1920×1080 の PNG だけを受け付ける。成功すると begin の控えを消す）
7. 成功でも失敗でも、`-s=<cards 用> close` とサーバの停止を行う

### compose

1. `python3 $S/compose.py --dir <dir>`（引数の中身を確かめたいときは `--dry-run`）。前の段が done でなければ ffmpeg を呼ばずに止まる
2. `over:` が出たら完了にしない。利用者と詰め方（`speed`・`pause_scale`・`gap_seconds`・先に削る行）を決めて該当の段に戻る（台本を削るなら再承認）
3. 出力の長さ・解像度を ffprobe で確かめ、数コマを Read で確かめる
4. `scenes.py status` で全段 done を確かめて報告する（出力のパス・長さ・クレジット・`data-changes.md` の戻し忘れが無いこと）

## 止まる条件

次のときは進めず、状況と選択肢を利用者に示す。

- 依存（playwright-cli・ffmpeg・ffprobe・声のエンジン）が無い（案内して止める）
- 声の規約の確認が取れない
- 撮影データの書き込みの了承が無い（読むだけで撮れる見せ方を相談する）
- 録画の後にぼかし漏れ・`badpattern` がある
- 台本の再承認が取れない
- 完成の尺が上限を超え、詰め方が決まらない

## してはいけないこと

- パスワード・ワンタイムコードの入力（ログインは利用者が行う）
- ソフトの導入・ダウンロードの無断実行（案内と、利用者の了承の後の実行だけ）
- 声の選択の代行・規約の当否の判断（規約の文面を見せて利用者に確かめてもらう）
- 利用者の了承なしの `scenes.py approve`
- 撮影用データの無断の書き込み（毎回確認し、控え、元に戻す）
- 会社固有の値（会の名前・画面名・ドメイン・人名・本番の数値）を skill 側のファイルへ書くこと（設定ファイルと `tmp/` にだけ置く）
