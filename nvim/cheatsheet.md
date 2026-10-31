# Cheatsheet

`<leader>?` で開閉、`q` で閉じる。覚えたら消し、知ったら書き足す（`:w` で保存）。

## 1. この設定の独自のキー（`<leader>` = Space）

| キー | 動作 |
|------|------|
| `<leader>?` | このシートの開閉 |
| `<leader>` を押して待つ | which-key がキーの一覧を出す |
| `<leader>ff` / `<leader>fg` / `<leader>fb` / `<leader>fr` / `<leader>fh` | telescope: ファイル / grep / バッファ / 最近のファイル / help |
| `<leader>e` | neo-tree の開閉 |
| `<Tab>` / `<S-Tab>` | 次 / 前の**バッファ**（タブページではない） |
| `<C-h>` / `<C-j>` / `<C-k>` / `<C-l>` | 左 / 下 / 上 / 右のウィンドウへ |
| `<C-d>` / `<C-u>` | 半画面スクロール（カーソルを中央に） |
| normal の `<Esc>` | 検索のハイライトを消す |
| `<leader>cf` | 整形（conform）。**保存時の自動整形は無い** |
| `<leader>tp` / `<leader>tr` / `<leader>tc` / `<leader>tl` | `tmp/plan.md` / `research.md` / `context.md` / `lessons.md` を開く |

### Git（fugitive）

| キー | 動作 |
|------|------|
| `<leader>gs` | Git status（`:Git`） |
| `<leader>gb` | blame |
| `<leader>gl` | log（`--oneline`） |
| `<leader>gh` | 今のファイルの履歴（`:0Gclog`。quickfix に出る） |

### PR のレビュー（atlas）

| キー | 動作 |
|------|------|
| `<leader>gd` | `:Atlas diff <既定のブランチ>...HEAD`（自分の変更） |
| `<leader>gp` | `:Atlas review`（open な PR を選ぶ。番号を指定するなら `:Atlas review <番号>`） |

差分のバッファの中だけで効くキー（**差分の中では全体のキーより優先される**。`<leader>gs` は Git status ではなくレビューの送信になる）:

| キー | 動作 |
|------|------|
| `c` / `C` | コメントを書く / 送る |
| `s` / `S` | suggestion を書く / 送る |
| `<leader>n` | note（自分だけのメモ）を足す |
| `<leader>gs` | レビューを送信する |
| `<leader>ga` / `<leader>gr` | Approve / Request changes |
| `<leader>t` | タスクを足す |
| `x` | スレッドの resolved を切り替える |
| `]c` / `[c` | 次 / 前のコメント |
| `]x` / `[x` | 次 / 前の未解決 |
| `]n` / `[n` | 次 / 前の note |
| `]f` `<Tab>` / `[f` `<S-Tab>` | 次 / 前のファイル |
| `]h` / `[h` | 次 / 前の hunk |
| `]u` / `[u` | 次 / 前の未レビューのファイル |
| `-` | ファイルをレビュー済みにする / 戻す |
| `K` | ファイル・コミットの詳細 |
| `<leader>b` / `<leader>e` | explorer の開閉 / explorer へ移る |
| `<leader>f` | explorer でファイルを探す |
| `gf` | ファイルを開く |
| `i` / `t` / `gc` | 表示の切り替え / layout の切り替え / compact の切り替え |
| `gT` | コメントのテンプレート |
| `gR` / `gD` / `gH` | review panel / detail panel / コメントの表示の切り替え |

差分のタブを閉じる（`:tabclose`）と一時 worktree が消える。

## 2. LSP（Neovim 0.12 の既定）

| キー | 動作 |
|------|------|
| `K` | 型・ドキュメント（hover） |
| `grn` | 名前の変更 |
| `gra` | code action |
| `grr` | 参照 |
| `gri` | 実装 |
| `grt` | 型定義 |
| `grx` | codelens の実行 |
| `gO` | ドキュメントのシンボル |
| `<C-]>` | 定義へ跳ぶ |
| `[d` / `]d` | 前 / 次の診断 |
| insert の `<C-s>` | シグネチャ |

## 3. 補完（blink.cmp の `preset = "default"`）

| キー | 動作 |
|------|------|
| `<C-y>` | 確定 |
| `<C-space>` | 補完を開く / ドキュメントの開閉 |
| `<C-e>` | 閉じる |
| `<C-n>` / `<C-p>`（`<Down>` / `<Up>`） | 次 / 前の候補 |
| `<C-f>` / `<C-b>` | ドキュメントのスクロール |
| `<Tab>` / `<S-Tab>` | スニペットの次 / 前の位置（insert モード） |
| `<C-k>` | シグネチャの開閉 |

## 4. telescope の中

| キー | 動作 |
|------|------|
| `<C-n>` / `<C-p>` | 候補の移動 |
| `<CR>` | 開く |
| `<C-v>` / `<C-x>` / `<C-t>` | 縦分割 / 横分割 / タブで開く |
| `<Tab>` | 複数選択 |
| `<C-c>` | 閉じる |

- fzf の記法: `'abc` 完全一致 / `^abc` 前方一致 / `abc$` 後方一致 / `!abc` 除外
- `:Telescope find_files hidden=true no_ignore=true cwd=<dir>`

## 5. Vim の基本

- **モード**: `i` / `a` / `o` 挿入、`v` / `V` / `<C-v>` visual、`:` コマンド、`<Esc>` normal に戻る
- **移動**: `w` / `b` / `e` 単語、`0` / `^` / `$` 行頭・行末、`gg` / `G` 先頭・末尾、`%` 対応する括弧、`f{c}` / `t{c}` 行内の文字へ、`<C-o>` / `<C-i>` ジャンプを戻る / 進む
- **編集（操作 + 範囲）**: `d` 削除・`c` 変更・`y` コピー × `w` 単語・`iw` 単語の中・`i"` 引用の中・`ip` 段落 など（例: `ciw`・`dap`・`yi(`）。`.` 繰り返し、`u` / `<C-r>` 戻す / やり直す
- **検索と置換**: `/` `?` 検索、`n` / `N` 次 / 前、`*` カーソルの単語、`:%s/old/new/gc`
- **ファイルとウィンドウ**: `:w` / `:q` / `:wq`、`:e <file>`、`:sp` / `:vs` 分割、`<C-w>c` 閉じる
- **タブページ**: `gt` / `gT` 次 / 前、`{数字}gt` その番号へ、`g<Tab>` 直前のタブ、`:tabnew` / `:tabclose`
- **バッファ**: `<C-^>` 直前のバッファ、`:bd` 閉じる

## 6. 注意

- ターミナルでは `<Tab>` と `<C-i>` を区別できないので、`<C-i>`（ジャンプを進む）も次のバッファになる
