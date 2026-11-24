# 台本（scenes.json と script.md）の型

台本の正本は `tmp/release-video/scenes.json`。`script.md` の表は `scenes.py table` が scenes.json から生成する（手で表を直さない）。補助スクリプトの呼び出しは `S=~/.claude/skills/release-video/scripts`（install 後。Codex は `~/.agents/skills/release-video/scripts`。この repo の worktree では `shared/skills/release-video/scripts`）。

## 作業ディレクトリ（`tmp/release-video/`）

| ファイル | 役割 | 書く人 |
|----------|------|--------|
| `script.md` | 台本（人が読む。`type: Video Script`） | Claude（表だけ `table`） |
| `scenes.json` | シーン定義（正本） | Claude |
| `approved.json` | 台本の承認（scenes.json の sha と日付） | `scenes.py approve`（利用者の了承の後） |
| `profile.json` | 解決した設定の写し | 最初のコマンド（`profile.md`） |
| `voice.json` | 選んだ声と規約の確認の記録 | Claude（利用者の答えを写す。`voice.md`） |
| `overlay.js` | 重ね表示（設定を埋め込んだもの） | `render.py overlay` |
| `rec.sh` | 撮影の実行用 | Claude が実行時に生成（`recording.md`） |
| `data-changes.md` | 撮影用データの書き込みの控え | Claude（書き込んだときだけ） |
| `trial/` | 試し読みの音声（公開しない） | `voice.py trial` |
| `audio/` `clips/` `cards/` `build/` | 素材と `manifest.json` | 各段 |
| `clips/<id>.meta` `cards/<id>.meta` | 素材を作る直前の入力の控え（mark が照合して消す） | `scenes.py begin` |
| `clips/session.json` | 撮影用の session に登録した overlay の印 | `scenes.py session` |
| `release-video.mp4` | 出力 | `compose.py` |

終了コード: 0=成功 / 1=入力やデータの誤り（stderr に 1 行）/ 2=引数の誤り / 3=外部コマンド・エンジンの失敗。どのスクリプトも `--dir`（既定 `./tmp/release-video`）と `--profile` を取る。

## 既定の段

設定（`profile.md`）に `talk.sections` が無いときの段。

| id | 内容 | 必須 |
|----|------|------|
| `intro` | 前置き（誰向けか） | |
| `conclusion` | 結論（今まで→これから） | ○ |
| `value` | 価値（ユースケースと課題） | ○ |
| `demo` | デモ | ○ |
| `omit` | 枝葉の省略 | |
| `caveat` | 注意点 | |
| `future` | 今後 | |

## scenes.json（version 1）

```json
{
  "version": 1,
  "title": "<機能名>",
  "max_seconds": 120,
  "gap_seconds": 0.5,
  "scenes": [
    {"id": "1", "section": "intro", "kind": "card", "seconds": 10,
     "screen": "タイトルカード", "telop": "<1 行の要約>",
     "narr": "<ナレーション>", "narr_reading": "<任意。読み上げ用の文>",
     "card": {"kicker": "<小見出し>", "lines": ["<本文 1>", "**<強調>**"], "sub": "<補足>"}},
    {"id": "4-1", "section": "demo", "kind": "record", "seconds": 12,
     "screen": "<画面と操作の説明>", "telop": "<テロップ>", "narr": "<ナレーション>"},
    {"id": "5", "section": "omit", "kind": "omit", "screen": "―", "telop": "<省略した内容>", "narr": ""}
  ]
}
```

- `id`: `^[0-9A-Za-z][0-9A-Za-z_-]{0,31}$`、重複不可（ファイル名に使う）
- `kind`: `card`（カード＋音声）／`record`（録画＋音声）／`omit`（台本の表にだけ出し、動画に入れない）
- `section`: 設定の `talk.sections[].id` のどれか（設定が無ければ上の既定の段）
- `seconds`: 目安の尺（正の数。`omit` 以外は必須）。`narr` が空のシーンは無音でこの尺だけ流す（`record` で `narr` が空なら録画もこの尺だけ撮る）
- `gap_seconds`: 任意。シーンの後ろに足す余白（既定 0.5、0 以上）
- `narr`: 必須（無いときは空文字）。`narr_reading` は任意で、あれば読み上げにそれを使う（整形を当てない）
- `card`: `kind: card` のとき必須（`kicker`・`lines`・`sub`）。`lines` の `**…**` だけが `<b>` になり、ほかの文字はすべてエスケープされる
- 未知のキーは誤り（打ち間違いが黙って無視されるのを防ぐ）。誤りは `scenes.py validate` が 1 行で止める

## 時間割（`measure` と `compose` の共通の計算）

`kind: omit` を除いたシーンごとに `長さ = max(音声, 映像) + gap_seconds`。音声は audio の manifest の `duration`（無ければ試し読みの長さ、それも無ければ文字数から 1 秒 6 字で推定）、`narr` が空なら 0。映像は録画なら clips の manifest の `duration`（無ければ `seconds`）、カードなら 0。`narr` が空のシーンは `max(seconds, 映像) + gap_seconds`。合計を `max_seconds` と比べ、超えたら `over:` を出す。

## 段の状態

`scenes.py status` が段（script → voice → record → cards → compose）ごとに `done`・`todo`・`stale`・`restore`・`over` を出し、最後の行に `next: <段>` を書く。判定は入力の sha と素材の中身の sha で行う（更新時刻は使わない）。

- script: 承認した sha が今の scenes.json と一致し、表も一致 → done。承認の後に台本が変わったら stale（再承認待ち）
- voice・record・cards: 全 id がそろい、入力の sha と素材の中身が記録と一致 → done
- record: `data-changes.md` に、「戻した日時」か「戻したことの確認」が空の行（`-` だけも空とみなす）・読めない行・読めない見出しがあると `restore`（done にならない。読めない控えは戻していないとみなす）。台本が読めないときも、record の行に戻していない画面を出す
- compose: 入力の sha・出力の中身が一致し、尺が上限以内 → done。上限超過は `over`

## script.md の雛形

`type: Video Script` の frontmatter を持つ。表は印の間だけを `scenes.py table` が書き換える。

<!-- tmp-frontmatter: tmp/release-video/script.md -->
```markdown
---
type: Video Script
title: <機能名>のデモ動画の台本
description: <誰向けの何分の動画か（1 文）>
status: draft
---
# <機能名>のデモ動画の台本

## 条件（長さの上限・解像度・声・型の出典）

- 長さ: <上限の秒数>。解像度 1920×1080
- 声: <エンジンと声の名前。未決なら「未決」>
- 型の出典: <共有会の型・設定ファイルの有無（無ければ「設定なし（探した場所: …）」）>

## シーン一覧

<!-- scenes:begin -->
<!-- scenes:end -->

## 尺が超えたら先に削る行

- <id と理由>

## 要確認事項（本番の数値・人名・声・読み）

- [ ] <利用者に確かめること。確かめるまで仮の表現にする>

## 撮影の前に確かめること

- [ ] <各場面で見せたい画面に中身があるか>

## 決めていないこと

- <未決の事項>
```

## 台本を書くときの規律

- 開発の言葉ではなく、見る人（営業・CS・顧客など、設定の `talk.audience`）の言葉で書く
- 本番の数値・人名は「要確認事項」に上げ、利用者が確かめるまで仮の表現にする。推測で埋めない
- 価値タスクを読めない（URL に届かない）ときは、本文の貼り付けを頼む
- 台本を直したら `scenes.json` を直して `table` を流し、承認の後なら差分を見せて再承認を取る
