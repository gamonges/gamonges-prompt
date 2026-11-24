# 設定ファイル（profile.json）

会社・プロダクト固有の値（共有会の名前・配色・読みの置き換え・撮影先の起点など）は、この repo の skill のファイルには書かない（PUBLIC のため）。**設定は対象 repo ではなく、実行する人の手元のファイル**に置く。会社固有の語（会の名前・画面名・ドメイン・読みの置き換え）はここにだけ書く。

## 探し方と写し

すべてのスクリプトが同じ順で探す（`rv_common.resolve_profile`）。

1. `--profile <file>`
2. 作業ディレクトリの写し `profile.json`
3. 環境変数 `RELEASE_VIDEO_PROFILE`
4. 無し（既定の段・既定の配色・既定のぼかしで進める。台本の「条件」と報告に「設定なし（探した場所: …）」と書く）

- 最初に解決した結果は、その場で作業ディレクトリの `profile.json` に写す（設定なしは `{"_source": "none", "_searched": [...]}`）。以後のコマンドは**写しだけ**を読み、環境変数は見ない。段ごとに違う設定で作られる経路を無くすため（入力の sha に設定由来の値が入る）
- **設定ファイルを直したら `--profile <file>` を付けて 1 回打つ**。写しが置き換わり（stderr に「設定を置き換えた（旧 → 新）」）、設定に依存する段（brand → cards、置き換え表 → voice）が stale になる
- `_source`・`_searched` は写しにだけ置く予約のキー。利用者の設定ファイルに書くと誤り

## キー

すべて任意。未知のキーは誤り（`scenes.py validate` が止める）。

```json
{
  "talk": {"name": "<共有会の名前>", "audience": "<誰向けか>", "max_seconds": 120,
           "tone": "<言葉づかいの指示>",
           "sections": [{"id": "intro", "label": "前置き", "required": false, "guide": "誰向けか"}]},
  "brand": {"logo_text": "", "font_family": "\"Hiragino Sans\",\"Noto Sans JP\",sans-serif",
            "colors": {"bg_from": "#0f1a36", "bg_to": "#1d3266", "text": "#ffffff",
                       "accent": "#5fd3e6", "emphasis": "#ffd166", "muted": "#9fb3d9"}},
  "privacy": {"blur_patterns": ["<足す正規表現>"], "blur_defaults": true},
  "reading": {"replacements": [{"from": "<表記>", "to": "<読み>"}]},
  "recording": {"base_url": "<撮影先の起点>", "session": "relvideo"}
}
```

| キー | 意味 | 既定 |
|------|------|------|
| `talk.sections` | 段の一覧（`scenes.json` の `section` はこの id から選ぶ） | `script-format.md` の既定の段 |
| `talk.audience`・`talk.tone` | 台本の書き方の指示（Claude が読む） | 無し |
| `brand` | カードの色・フォント・ロゴの文字。色は `#rgb` 形式だけ、`font_family` は英数字・`,"'-_.` と日本語の文字だけ許す（CSS に流し込むため） | 上の例の値 |
| `privacy.blur_patterns` | ぼかす文字列の正規表現。**既定に足す** | 無し |
| `privacy.blur_defaults` | `false` を明示したときだけ、既定のぼかしを外す | `true` |
| `reading.replacements` | 読み上げの置き換え表（長い `from` から当てる） | 無し |
| `recording.base_url`・`recording.session` | 撮影先の起点と playwright-cli の session 名 | 無し |

- 既定のぼかしは、メールアドレスの形すべて（安全側）。デモで見せたいテスト用のアドレスがあるときだけ `blur_defaults: false` にし、隠したい形を `blur_patterns` に自分で書く
- `blur_patterns` の各式は `render.py overlay` が検証する。python で通らない式、node があれば JS で通らない式は exit 1 で止まる。重ね表示の側でも通らない式は飛ばさず `window.__ov.log` に `badpattern` として積むので、録画の後の確認（`recording.md`）で 1 件でもあれば録画を使わない

## 空の雛形

```json
{}
```

設定が無くても進められる。段・配色・ぼかしは既定になり、会社固有の語（共有会の名前など）は台本や報告に出てこない。
