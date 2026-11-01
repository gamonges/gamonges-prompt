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
| `<leader>prismad` | カーソル下の TS の型名から `.prisma` の enum / model / type / view の定義へ飛ぶ（名前で探す。複数なら quickfix。差分の中では新しいタブに開く） |
| `<leader>tp` / `<leader>tr` / `<leader>tc` / `<leader>tl` | `tmp/plan.md` / `research.md` / `context.md` / `lessons.md`（廃止予定）を開く |

### コマンドの短縮形（`:` の直後に打ったときだけ展開する）

| 打つ | 展開 |
|------|------|
| `:mp` | `:MarkdownPreviewToggle` |
| `:at` | `:Atlas`（`:at review` のように引数も続けられる） |

### Git（fugitive）

| キー | 動作 |
|------|------|
| `<leader>gs` | Git status（`:Git`） |
| `<leader>gb` | blame |
| `<leader>gl` | log（`--oneline`） |
| `<leader>gh` | 今のファイルの履歴（`:0Gclog`。quickfix に出る） |

### Claude Code（claudecode.nvim）

Orca の別ペインにいる Claude Code に、ファイルや選択範囲を渡す。先に Claude 側で `/ide` を打って接続しておく。

| キー | 動作 |
|------|------|
| `<leader>a` | グループ（押して待つと which-key に一覧が出る） |
| visual の `<leader>as` | 選択範囲を Claude に送る |
| `<leader>ab` | 今のバッファを Claude に渡す |
| neo-tree の中の `<leader>as` | カーソル下のファイルを Claude に渡す |
| `<leader>ai` | 接続の状態 |

atlas の差分のタブでは、未接続のまま送ると何も送らずに警告だけ出る（そのタブの cwd では参照のパスがずれるため）。

### PR のレビュー（atlas）

| キー | 動作 |
|------|------|
| `<leader>gd` | `:Atlas diff <既定のブランチ>...HEAD`（自分の変更） |
| `<leader>gp` | `:Atlas review`（open な PR を選ぶ。番号を指定するなら `:Atlas review <番号>`） |

差分のバッファの中では、atlas のキーが全体のキーより優先される（atlas は `nowait` で張る）。次の全体のキーは差分の中では使えない:

- `<leader>f*`（`ff`・`fg`・`fb`・`fr`・`fh`）: `<leader>f` が先に効き、explorer でファイルを探す
- `<leader>t*`（`tp`・`tr`・`tc`・`tl`）: `<leader>t` が先に効き、タスクを足す
- `<leader>e`: neo-tree ではなく atlas の explorer へ移る
- `<leader>gs`: Git status ではなくレビューの送信になる
- `<Tab>` / `<S-Tab>`: バッファではなくファイルを移る
- `K`: LSP の hover ではなく、ファイル・コミットの詳細を出す。型を見るなら `gf` でファイルを新しいタブに開いてから `K`
- `gT`: 前のタブではなく、コメントのテンプレートを出す（タブは `:tabprevious`）
- `gD` / `gc`: 宣言へ移る・コメントアウトではなく、detail panel・compact の切り替えになる

差分のバッファの中だけで効くキー（atlas `dd8bf80` の既定。網羅）:

| キー | 動作 |
|------|------|
| `c` / `C` | コメントを pending に積む / その場で投稿する（explorer の中ではファイルへのコメント） |
| `s` / `S` | suggestion を pending に積む / その場で投稿する |
| `<leader>n` | note（自分だけのメモ）を足す |
| `<leader>gs` | pending を Comment としてレビューを送る |
| `<leader>ga` / `<leader>gr` | pending を Approve / Request changes として送る |
| `<leader>t` | タスクを足す |
| `x` | スレッドの resolved を切り替える |
| `]c` / `[c` | 次 / 前のコメント |
| `]x` / `[x` | 次 / 前の未解決 |
| `]n` / `[n` | 次 / 前の note |
| `]f` `<Tab>` / `[f` `<S-Tab>` | 次 / 前のファイル |
| `]h` / `[h` | 次 / 前の hunk |
| `]r` / `[r` | 次 / 前のコミット |
| `]u` / `[u` | 次 / 前の未レビューのファイル |
| `-` | ファイルをレビュー済みにする / 戻す |
| `K` | ファイル・コミットの詳細 |
| `<leader>b` / `<leader>e` | explorer の開閉 / explorer へ移る |
| `<leader>f` | explorer でファイルを探す |
| `gf` | ファイルを開く |
| `i` / `t` / `gc` | 表示の切り替え / layout の切り替え / compact の切り替え |
| `gT` | コメントのテンプレート |
| `gR` / `gD` / `gH` | review panel / detail panel / コメントの表示の切り替え |
| `gC` | explorer のコミットの一覧の切り替え |
| `gA` | 外部の差分ビューアのヘルプ |
| `f`（review panel の中） | panel の表示の絞り込みを切り替える |

差分のタブを閉じる（`:tabclose`）と一時 worktree が消える。

#### レビューの手順（`:at review` / `<leader>gp` で PR を開いてから）

0. **（任意）AI の指摘を下敷きにする**: note は PR を開くときに読まれるので、開く前に済ませる。差分のタブを `:tabc` で閉じ、PR の head を checkout した worktree で `/review` → `python3 ~/.claude/scripts/review-to-atlas-notes.py --pr <番号>`（`--dry-run` で予定だけ）→ `:at review <番号>` で開き直す。`]n` / `[n` で辿る
1. **全体を掴む**: `gR` で review panel、`gC` でコミットの一覧、`]r` / `[r` でコミットを移る、`K` で詳細
2. **ファイルごとに読む**: `]u` で次の未レビューのファイルへ → `]h` / `[h` で hunk を移る → 読み終えたら `-` で済みにする。型や定義を見るときは `gf` で新しいタブに開いて `K` / `<C-]>` を使い、**そのタブだけ** `:tabc` で閉じて戻る（差分のタブを閉じると一時 worktree が消える）
3. **指摘を書く**: 基本は `c` / `s` で pending に積む（`C` / `S` は 1 件ずつ即座に投稿され、通知も 1 件ずつ飛ぶ）。`gT` でテンプレート、自分だけのメモは `<leader>n`
4. **送る**: `<leader>ga`（Approve）・`<leader>gr`（Request changes）・`<leader>gs`（Comment）のどれか 1 つで、積んだ pending をまとめて送る。差分の中の `<leader>gs` は Git status ではない
5. **終える**: 差分のタブを `:tabc` で閉じる

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
