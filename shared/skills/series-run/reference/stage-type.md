# 段の型（作業単位の工程）

1 つの作業単位（worktree）を、どの工程の順に、誰が、何を証拠に進めるかの定義。series-run の SKILL.md・worker の spec（`./worker-spec.md`）・状態ファイル（`./state-format.md`）はこの表の工程名と完了の証拠を参照し、写しを持たない。工程を替える（例: review の skill を替える）ときは、この表だけを直す。

ツールのコマンドはここに書かない。起動・待ち合わせ・再試行は adapter の操作名で書く。

## 前提: 作業単位の段は 1 つ

series-init は同じリポジトリでスタックになる段を 1 つの worktree にまとめる（`../../series-init/SKILL.md:L53`）。段が 2 つ以上の作業単位を回すには、スタックの初期化・段の境目でのレイヤーの追加・ブランチごとの review と push が要り、まだ検証していない。段が 2 つ以上の作業単位は、どの工程も起動せず `対象外` にして、次のどちらかを案内する。

- 段ごとに worktree を分ける。series-run の初動では、series-init の確認の中で分けられる（SKILL.md の 1）
- その worktree を手で回す

## 工程

| 工程 | 担当 | 起動する skill | 入力（その skill の実行条件を満たす状態） | 出力 | 完了の証拠 | 次 |
|------|------|---------------|------------------------------------------|------|-----------|----|
| design | worker | `/design` | `tmp/context.md`（series-init の引き継ぎ。`outline:`・`series:` を持つ） | `tmp/plan.md` | 完了報告が成功、かつ `tmp/plan.md` の更新時刻が試行の起動時刻より後（前の試行・既存の worktree の残骸で通さない） | plan-lgtm |
| plan-lgtm | worker | `/plan-lgtm tmp/plan.md` | design の完了の証拠（`tmp/plan.md`） | `tmp/plan-review.md`（revise が `tmp/plan.md` を直す） | 完了報告が成功、かつ `tmp/plan-review.md` の `**総合判定**` が LGTM・`**対象**` が `tmp/plan.md`・plan-review.md が plan.md より新しい（plan-lgtm と同じ 3 点）、かつ plan-review.md の更新時刻が試行の起動時刻より後（前の試行・既存の worktree の残骸で通さない） | implement |
| implement | worker | `/implement tmp/plan.md` → push（下の「push の手順」） | LGTM の `tmp/plan.md` | コミット・リモートのブランチ | 完了報告が成功、かつ `git -C <wt> log <工程の基準の HEAD>..HEAD` が空でなく、`git -C <wt> rev-parse @{u}` が HEAD と一致 | pr |
| pr | ユーザー（④） | `/create-pr` | リモートのブランチ（`/create-pr` は push の手順を持たず、`gh pr create --head <今のブランチ>` を打つだけ。`../../create-pr/SKILL.md:L231-239`） | open のドラフト PR | `gh pr list --repo <段のリポジトリ> --head <ブランチ> --state open` に PR があり、series.md の `## 段` のその段に PR が登録された。`<ブランチ>` は `git -C <wt> branch --show-current`（series.md のブランチ列は、この登録で初めて埋まる）。coordinator は別のリポジトリで動くことがあるので `--repo` を付ける | checks |
| checks | coordinator | — | open の PR と push 済みの HEAD | `tmp/checks.md`（CI の失敗と bot の P0/P1、`## 参考` の thread） | 下の「checks の工程」の判定が済んだ | review（`前: implement`）。`前: fix` は下の「checks の工程」の 5 の取り込みだけの判定の後に recheck か③。`前: fix-light` は下の「軽い fix」の 6 |
| review | worker（claude に固定） | `/review` | 今のブランチに open の PR がある（`../../review/SKILL.md:L95-102`。無いと止まる） | `tmp/review/unified.md` | 完了報告が成功、かつ unified.md の更新時刻が試行の起動時刻より後（review はコミットを作らないので HEAD では判定できない。recheck のような件数の行は求めない。unified.md は review の skill が決まった書式で書き、件数のサマリーを持つため） | triage |
| triage | coordinator | — | unified.md・横断計画・series.md | `tmp/fixes.md`（`../../fix/reference/category-examples.md:L6-22` の形） | 指摘ごとの仕分け（直す / 後の段 / 直さない）を状態ファイルに記録した | fix（直すものが 0 件なら、下の「仕分け（triage）が 0 件のとき」） |
| fix | worker | `/fix-lgtm-implement tmp/fixes.md` → push（下の「push の手順」） | `tmp/fixes.md`（fix の実行条件。`../../fix-lgtm-implement/SKILL.md:L22`） | 追加のコミット・リモートのブランチ | implement と同じ（工程の基準の HEAD からの新しいコミットと、`@{u}` と HEAD の一致）。新しいコミットが無いときは、下の「fix が新しいコミットを作らなかったとき」 | checks |
| fix-light | worker | `/fix tmp/fixes.md` → `/implement tmp/fix-plan.md` → push（下の「push の手順」。plan-lgtm を通さない: 下の「軽い fix」） | `tmp/fixes.md`（coordinator が checks の指摘から書く） | 追加のコミット・リモートのブランチ | fix と同じ（工程の基準の HEAD からの新しいコミットと、`@{u}` と HEAD の一致）。新しいコミットが無いときは、下の「軽い fix」の 7 | checks（`前: fix-light`） |
| recheck | worker（claude に固定） | `/code-review <強さ> <PR 番号>`（下の「recheck の工程」） | fix か fix-light の完了の証拠（push 済み）と open の PR | `tmp/code-review.md` | 完了報告が成功、かつ `tmp/code-review.md` の更新時刻が試行の起動時刻より後、かつ frontmatter の直後の本文の 1 行目の対象と強さが spec と一致し、2 行目に `指摘: <件数> 件（新規 <n>・既決 <m>）` があって `<n>` と `<m>` の和が `<件数>` と一致する（件数の行が無ければ、レビューできなかったとみなし、証拠を満たさない。0 件と取り違えない） | 完了（指摘が 1 件以上か、直前の checks（`前: fix` か `前: fix-light`）の `tmp/checks.md` に指摘があれば、下の「recheck の工程」の 4） |

- 前の工程の完了の証拠は、次の工程の入力（実行条件）を含む。implement の push が無いと `/create-pr` が作る PR の head が無く、pr の工程の open の PR が無いと `/review` が止まる
- review の worker を claude に固定するのは、Codex では `~/.agents/skills/review` に同名の別実装があると `tmp/review/unified.md` が作られないため（この repo の `README.md:L121`。実行時に読む必要は無い）。recheck を claude に固定するのは、組み込みの `code-review` が Claude Code にしか無いため。ほかの工程は claude を既定にし、状態ファイルの `## 運用の約束` で工程ごとに変えられる
- 1 つの worktree には同時に 1 体の worker だけを入れる。工程は `tmp/` の成果物を前の工程が書いて次の工程が読むので、並列にするのは worktree の間だけ
- design と plan-lgtm を別の worker に分けるのは、計画を作るモデルと、レビュー・修正を反復するモデルを別にするため（既定の理由は「worker のモデルと advisor」）。plan-lgtm の worker の問いへの答えでループを抜けるときは、下の「再設計で design に戻す」「plan-lgtm を中断で抜ける」に従う

## 再設計で design に戻す

plan-lgtm の worker が `要再設計` で「`/design` で再設計する」を問うてきたら、③としてユーザーに聞く。ユーザーが再設計を選んだら、次の順に行う（plan-lgtm のモデルで計画を作り直さないため）。

1. 答えは `## ユーザーの決定` に書かない（工程の流れだけを決める答えで、以後の工程の spec に写す決定ではない）。代わりに、問いを出した worker の試行の行（`## 工程の記録`）の要約に、送る前と送った後の 2 段で書く。返してから書くと、失敗の報告が届くまでの間に再開したとき答えを失い、通常の再試行に落ちる。返す前に「返答済み」と書くと、書いてから返すまでの間に切れたとき、答えが worker に届かないまま互いに待つ
   1. worker に返す前に「`Q-<n>`: 再設計を選んだ（送信前）」と書き、`## ユーザーへの依頼` のその行を `回答済み` にする
   2. 下の 2 で返し、adapter の「質問に答える」の応答が成功だったのを確かめてから、同じ記述を「`Q-<n>`: 再設計を選んだ（返答済み・失敗報告待ち）」に書き換える
   3. 再開で「（送信前）」が残っていたら、adapter の「再開」の送り直しに従う（SKILL.md の 0 の「再開」）
2. その worker には、adapter の「質問に答える」で「`/design` は打たずに plan-lgtm を中断し、失敗で報告する。残りに『再設計で戻す』と書く」と返す
3. その失敗の報告は、その試行の行の要約に「再設計を選んだ」（送信前・返答済みのどちらでも）があり、残りに「再設計で戻す」があるものだけをこの扱いにする（どちらかが無ければ「失敗したとき」の通常の扱い）。この扱いに決まったら、要約の同じ記述を「再設計で戻す（`Q-<n>`）」に書き換え、`tmp/plan-review.md` の `**総合判定**` と Critical の見出しを写す（次の plan-lgtm が plan-review.md を作り直しても、戻した理由が残る）。再試行に数えず、worker を adapter の「worker を解放する」で解放し、続けて SKILL.md の手順の 3 の 1〜5 で design を「worker の起動」で起動する（作業単位は `plan-lgtm: 作業中` から直接 `design: 作業中` にする）
4. 巡を 1 つ進める。工程の記録には design を `2-1`（3 巡目は `3-1`）と書き、続く plan-lgtm も同じ巡で 1 から数える。試行の上限の 2 回は巡ごと。工程の基準の HEAD も取り直す（「fix の 2 巡目」と同じ書き方）
5. design の spec の Change には「`tmp/plan-review.md` の要再設計の指摘を読み、それを解消する計画を作る。既存の `tmp/plan.md` は作り直す（`/design` が上書きを問うたら上書き）」と書く。工程の再試行は spec を差し替えないので、この巡の試行すべてに効く
6. 次の巡に入るかも、そのつど同じ③でユーザーが決める（自動では戻さない）。巡に上限は置かない（毎回ユーザーが決めるので、自動で回り続けない）

分割前の状態ファイルから再開した旧 worker（`/design` と `/plan-lgtm` を両方回す）も、この節と次の節に従う。行と状態の読み替えは SKILL.md の「分割前の状態ファイルからの再開」。

## plan-lgtm を中断で抜ける

plan-lgtm の worker の問い（`../../plan-lgtm/SKILL.md:L53-54`）に、ユーザーがループを抜ける答えをしたとき。ループを抜ける答えは次の 4 つ。

- 要再設計の「中断する」
- 上限（反復が 1 回以上）の「ここで打ち切りユーザーが手動介入する」「中断する」
- 上限（反復が 0 回）の「このまま中断する」

「このまま続行を試みる」「反復を継続する」「`revise` を1回試みる」はループを抜けない。この節に入れず、通常の③の答えとして worker に返す。

1. 「再設計で design に戻す」の 1 と同じく、`## ユーザーの決定` に書かず、試行の行の要約に 2 段で書く（「`Q-<n>`: 中断を選んだ（送信前）」→「（返答済み・失敗報告待ち）」）。再開の送り直しも同じ
2. worker には、adapter の「質問に答える」で「plan-lgtm を中断し、失敗で報告する。残りに『中断（ユーザーの答え）』と書く」と返す
3. 失敗の報告の残りに「中断（ユーザーの答え）」があり、試行の行の要約に 1 の記述（送信前・返答済みのどちらでも）があるときだけ、この扱いにする。再試行に数えず、worker を adapter の「worker を解放する」で解放し、要約の記述を「中断（`Q-<n>`）」に書き換える。作業単位を `plan-lgtm: 判断待ち` にし、③で次を聞く
   - plan-lgtm を起動し直す: adapter の「工程の再試行」で起動する（spec は差し替えない）。試行の回数は前と続けて数え、上限の 2 回を超えるときは、この③の答えをもって 1 回だけ足す
   - design に戻す: 「再設計で design に戻す」の 3 の design の起動（SKILL.md の手順の 3 の 1〜5）と、4〜6 を行う（worker は解放済み。作業単位は `plan-lgtm: 判断待ち` から `design: 作業中` にする。戻した理由には `Q-<n>` の答えを写す。上限で抜けたときの plan-review.md は `要修正` なので、5 の Change の「要再設計の指摘」は「残っている指摘」と書く）
   - 手で進める: `対象外`

## 工程の基準の HEAD と、試行の起動時の HEAD・時刻

worker を起動する直前に、`git -C <wt> rev-parse HEAD` と起動時刻を、状態ファイルの `## 工程の記録` のその試行の行に書く（試行の起動時の HEAD・時刻）。その工程の 1 回目の試行では、同じ HEAD を「工程の基準の HEAD」にも書き、再試行・再開では書き換えない。

- implement・fix・fix-light の「新しいコミット」は、工程の基準の HEAD から数える。前の試行がコミットした後に push だけで失敗したとき、再試行は前の試行のコミットを確かめて push だけを再開してよい（成果は工程の単位で評価する）。worker は段の型を読まず、工程の再試行は spec を差し替えないので、このことは 1 回目の spec の Change に最初から書いておく（`./worker-spec.md` の埋め方）
- design・plan-lgtm・review・recheck の「起動時刻より後」は、試行の起動時刻を使う（前の試行の成果物を今回の成果と取り違えないため）。plan-lgtm の再試行は、前の試行が revise で直した `tmp/plan.md` を入力にそのまま回し直す（review-plan は `tmp/plan-review.md` を毎回作り直すので、判定は今回の試行のものになる）

## push の手順

implement・fix・fix-light の worker が使う。初回かどうかの判定をここ 1 か所に置く。「残り」に「手順 N」と書くのは、下の手順が push を止めたときだけ。push のコマンドそのものが通信の障害などで失敗したときは、番号を書かずに失敗で報告する（coordinator は通常の失敗として再試行する）。照合に使う値（worktree のパスと段のリポジトリ）は、coordinator が spec の Target に書く。series.md のブランチ列と worktree 列は照合に使わない（ブランチ列は `/create-pr` の register が埋めるまで空。worktree 列は handoff に回った段では、`/create-pr` の register が埋めるまで空。`../../series-init/SKILL.md` の「下書き → check → write」）。

- **`<branch>` の書き方**: 下の手順の `<branch>` は、`git -C <wt> branch --show-current` の値を、コマンド置換（`$(...)`）を使わずにそのままコマンドに書く。コマンド置換は、破壊的な git を確かめる hook が押す先を判定できず、確認で止まる。押す先を `HEAD:<branch>` で明示するのは、`@{push}`（upstream と `push.default`）の解決に頼らないため（refspec の無い `git push` は、upstream の無いブランチで hook が押す先を求められずに確認で止まる）
- **push の前の検査**（手順の番号は付けない）: `## 運用の約束` の「検査のコマンド」を worktree で回す。落ちたら直してからもう一度回し、通ってから下の 1 へ進む。直すのに計画の変更対象の外に触れる必要があるとき、または直せないときは、push せず、番号を書かずに失敗で報告する（push の手順で止めた③ではなく、通常の失敗として再試行する）。「要らない」なら飛ばす。重い検査（typecheck など）は書かず、checks の CI に任せる（運用の約束で決める）
1. **前の段の取り込みの確認**: 自分の段の base が、シリーズの別の段を指す（指す先の段のブランチ名か、`段 <名> に積む` の形）ときだけ行う。指す段のブランチは、その段の worktree で `git -C <その wt> branch --show-current` で引く（coordinator が spec の Change に書く）。`git -C <wt> fetch origin` の後に `git -C <wt> log HEAD..origin/<そのブランチ>` が空であることを確かめる。空でなければ push せず、完了報告の「残り」に「手順 1: 前の段の取り込み漏れ」と書く。ブランチが引けなければ、確認を省かずに push せず、「残り」に「手順 1: 前の段のブランチが引けない」と書く
2. `git -C <wt> rev-parse --abbrev-ref @{u}` が失敗する（upstream が無い。series-init は upstream を外す。`../../series-init/SKILL.md:L97`・L101）なら、`git -C <wt> rev-parse --show-toplevel` が spec の Target の worktree と一致し、`git -C <wt> remote get-url origin` から取り出した `<owner>/<repo>`（`github.com[:/]<owner>/<repo>(.git)?` の形）が spec の Target のリポジトリと一致することを確かめてから `git -C <wt> push -u origin HEAD:<branch>`。一致しなければ push せず、「残り」に「手順 2: 照合の不一致」と書く
3. upstream があれば、`git -C <wt> rev-parse --abbrev-ref @{u}` が `origin/<git -C <wt> branch --show-current の値>` であることを確かめてから `git -C <wt> push origin HEAD:<branch>`（handoff から作った worktree は、base のブランチを追跡していることがある）。違えば push せず、「残り」に「手順 3: upstream が今のブランチを向いていない」と書く
4. 強制の push はしない（④）。必要なら完了報告の「残り」に「手順 4: 強制の push が要る」と書く

## 起動の前の確認

- **作業単位の段の数**: 1 つであること（上の前提）
- **横断計画の worktree**: 作業単位の worktree が、状態ファイルを置く横断計画の worktree と同じなら起動しない。③として「段の worktree を別に作るか」を回す（その worktree の `tmp/plan.md` は横断計画で、`/design` の上書きで消えうる。状態ファイルも同じ `tmp/` にある）。作ると答えたら、coordinator が `../../series-init/SKILL.md` の「handoff」と同じ形で、その段の引き継ぎを横断計画の worktree の `./tmp/handoff/<repo>.md` に置き（この段は handoff に回っていないので、ファイルがまだ無い）、`## 作業単位` の worktree を空にし、作業単位を `worktree 待ち` にして SKILL.md の 2 の 3 と同じく `R-<n>`（そのファイルのパスを含む）を立てる。作らないと答えたら `対象外`。series-init の確認の中でも止める（SKILL.md の 1）。これは最後の網
- **順序**: base が別の段を指す段（push の手順 1 と同じ判定）は、指す段の `## 工程の記録` に、implement の行で成否が成功のもの（完了の証拠を確かめた）があることを確かめてから起動する。まだ無ければ③にせず、起動しないで待つ（時間が経てば満たされる条件なので。ほかの確認とは扱いが違う）。それ以外の段は、series.md の `順序` に関係なく並列に起動する。状態名は工程をまたぐ順序を持たないので、状態名ではなく記録で判定する。context.md の「前提」（本番に出ていること）は、ここでは判定しない（監督の開始のときに③でまとめて確かめる。SKILL.md の 2）
  - 指す段が `対象外` になったら（理由を問わず）、指す段の `## 工程の記録` に implement の成功の行が既にあれば何もしない（順序は満たされている）。無ければ、積む段を③に回す: 「積む段も `対象外` にするか、ユーザーが手で push したことを確かめて待ちを解くか」（積む段の状態は `./state-format.md` の `<工程>: 判断待ち` の規則で決める。`未着手` なら `design: 判断待ち`、`worktree 待ち` なら書き換えない）。待ちを解くと答えたら、`git -C <指す段の wt> rev-parse @{u}` が HEAD と一致することを確かめ（`@{u}` が無い・一致しないなら、その旨を示して同じ③に戻る）、指す段の `## 工程の記録` に implement の行を成否「成功（手で push。③の答え）」で足す（以後の順序の判定はこの行で満たされる）。積む段の状態は、`design: 判断待ち` にしていたなら `未着手` に戻す（`worktree 待ち` なら書き換えていない）。作業単位を `対象外` にするたびに、その段を指す段が無いかを見る
- **review・recheck の前の checks**: review は `checks: 済み`（`前: implement`）の後に、recheck は `checks: 済み`（`前: fix` か `前: fix-light`）の後に起動する（下の「checks の工程」）
- **review・fix・fix-light・recheck**: その段の PR が open であることを `gh pr view <PR> --repo <段のリポジトリ> --json state` で確かめる。`<PR>` は series.md の段の PR 列から取り、空なら（pr の工程で登録しないで進んだなど）`gh pr list --repo <段のリポジトリ> --head <git -C <wt> branch --show-current の値> --state open --json number` で引く（recheck の `<PR 番号>` も同じ）。pr の工程の後で、ユーザーが PR をマージしたり閉じたりすることがあるため（起動したときには PR が既にマージ済みだった事故がある）。open でなければ起動せず、③としてユーザーに回す
- **同じ worktree の worker**: 状態ファイルの `## adapter` で、その worktree の試行のうち、まだ終わっていない（完了報告を受け入れていない・止めていない）ものが無いこと。あれば起動せず、ユーザーに回す。完了報告の後に残した terminal（pr の工程でユーザーが操作した terminal など）は数えない

## worker のモデルと advisor

worker を起動する直前（工程の再試行を含む）に、その工程の `## 運用の約束` の model と effort と advisor を当てる。agent が codex の工程では、どれも当てない（Codex に advisor は無い）。fix-light の指定が無い運用の約束（fix-light より前に作った状態ファイル）では、fix の指定（agent を含む）を fix-light に当てる（どちらも同じ既定で、ユーザーが fix に決めた指定を外さないため）。

1. **model と effort**: adapter の「worker の起動」「工程の再試行」に model と effort を渡す（運用の約束に指定があるときだけ）。effort が無い工程（この項目より前に作った状態ファイルなど）は、effort を渡さない。effort があって model が無い組は、Orca の `--effort` が `--model` を要るので渡せない。③で聞き直す
2. **組み合わせの確認**: advisor を書く前に、実行モデルと advisor の組を次の表で確かめる。起動のたびに確かめる（初動・再開・再試行・監督の途中で運用の約束を変えた後のどれも、この起動の直前を通るため）。外れていたら `advisorModel` を書かずに起動を止め、③で「advisor を外して起動するか、advisor を替えるか」を聞く。advisor が実行モデルより下位だと、Claude Code はエラーを出さずに advisor を付けないため、黙って起動すると advisor 無しで動く

   | 実行モデル | 付けられる advisor |
   |-----------|-------------------|
   | `claude-fable-5-2` | `claude-fable-5-2` のみ |
   | `claude-opus-5-5` | `claude-fable-5-2`・`claude-opus-5-5` |
   | `claude-sonnet-5-5` | `claude-fable-5-2`・`claude-opus-5-5`・`claude-sonnet-5-5` |

   model と advisor の別名は、`opus` を `claude-opus-5-5`、`sonnet` を `claude-sonnet-5-5` と読み替えて引く（この項目より前の状態ファイルの advisor は `opus`）。`fable` は読み替えず、③で完全な ID を聞き直す（解決先がセッションの種類で変わるため。state-format の運用の約束と同じ）。表に無いモデルは組み合わせを判定せず、そのまま書いてよいかを③で聞く（推測で通さない）。advisor が無い工程は確かめない。model が無いのに advisor がある工程は、実行モデルが Claude Code の既定に決まって表を引けないので、同じく③で聞く。出典は Claude Code の docs の advisor の「Choose an advisor model」

   この節の③（1 と 2）を待つ間は、作業単位を起動しようとした工程の `<工程>: 判断待ち` にする（`./state-format.md` の状態の表）。答えのとおりに `## 運用の約束` を直してから、同じ工程を同じ操作（worker の起動か工程の再試行）で起動し直す。そのときも 1 から当て直す。「そのまま書いてよい」と答えた組は、運用の約束のその工程に「組み合わせはユーザーが確かめ済み」と控え、以後の起動では聞かない（控えないと、起動し直すたびに同じ③が立つ）。その工程の model か advisor を変えたら、控えを外す
3. **初回の確認**: その worktree で最初に書く前に、`git -C <wt> check-ignore -v .claude/settings.local.json` で無視の対象かを確かめ、結果を `## 運用の約束` に控える。対象でなければ書かずに③で聞く（コミットに混ざるため）
4. **advisor**: `<wt>/.claude/settings.local.json` の `advisorModel` キーだけを、Bash から python で書き換える（JSON を読み、指定があればキーを足し・指定が無ければ外し、ほかのキーはそのまま書き戻す。ファイルが無く外すだけなら作らない）。Edit・Write ツールは使わない（`.claude/` の下の書き込みに確認が出うる）。前の起動の状態を信じず、起動のたびに工程の指定どおりに書く
5. **起動の後**: キーを読み直す。指定と違えば（起動の途中で書き換えられた）書き直さずに③で回す（毎回の起動で起きるなら、起動の後に書く形へ替えるかをユーザーが決める）

既定値（state-format の `## 運用の約束`）の理由。値そのものは state-format だけに置く:

- design: 計画の誤りは下流の全工程に広がるので、計画を作る 1 回だけ最も能力の高いモデルを使う（料金の高いモデルを、レビューと修正の反復に使わないため）
- plan-lgtm: レビューと修正の反復を、計画を書いたモデルとは別のモデルで回す。レビューは Opus の強み。初回の review-plan が起動する Codex も、もう 1 つの独立した目になる
- implement・fix・fix-light: LGTM の計画は仕様が明確なので Sonnet で足りる（fix-light は CI・bot の指摘の小さな修正）。迷う箇所だけ advisor に聞く。effort は xhigh より下に留める（xhigh 以上の Sonnet は自分からレビュー用のサブエージェントを起動し、`/implement` のレビューの反復と重なる）
- review・recheck: レビューは Opus の強み。実装した Sonnet とは違うモデルで読む。recheck は `/code-review` の強さで深さを決めるので、セッションの effort は review より下げる
- effort を明示するのは、渡さないと worker の effort が設定の継承やモデルの既定（`medium`）で決まり、工程の意図から外れるため

## pr の工程

1. implement の工程の完了の証拠を確かめたら、`## 工程の記録` に pr の行を 1 行足し（試行・HEAD の欄は空、起動時刻はこの時刻。要約の欄は 4 の回数と、登録しないで進んだときの理由に使う）、作業単位を `ユーザーの操作待ち（/create-pr）` にし、adapter の「worker の terminal を残す」で implement の worker の terminal を残す
2. 意味のカードを書き、HTML にして開く（`./meaning-card.md`。`round: implement`）。その terminal で `/create-pr` を打つよう、worktree と terminal を名指しし、カードの HTML のパスを添えて案内する（カードの前半が `/create-pr` を打つ前に見る材料）。worker は完了報告を送った後なので、ユーザーが打った `/create-pr` はユーザー自身の作業になり、その中の質問（通常の PR かスタックか など）はユーザーに直接出る（worker の契約の最後の項）
3. ユーザーが作ったと伝えたとき、出来事を 1 つ処理するたび、待ち受けが時間切れになるたび、worker が 0 体でターンを終える前とユーザーの返事が来るたび（SKILL.md の 4 の「待つ相手の worker が居ないとき」）に、完了の証拠を確かめる。ユーザーの返事が無くても、証拠がそろえば進む（タイミングの正典はここ。SKILL.md はここを参照する）
4. 3 の確認で、open の PR はあるが series.md に登録が無い（register が衝突・候補なしで書かなかったなど）のが 2 回続いたら（出来事の処理・時間切れ・ターンを終える前のどの確認でも数える。続いた回数は `## 工程の記録` の pr の行の要約に「登録なし: <回数>」と書き、再開しても数を失わない）、PR と登録のどちらが欠けているかを示し、③として「`/series-sync` で登録し直すか、登録しないで進むか」を回す（登録し直すのはユーザー。`/series-sync` は register の書き手の口）。同じ作業単位にこの③は 1 回だけ立てる（`未回答` の間は、時間切れのたびに立て直さない）。作業単位の状態は `ユーザーの操作待ち（/create-pr）` のまま変えない。答えの前に登録がそろって進んだら、この③を `取り下げ` にする。登録し直すと答えたら 3 の確認に戻る。登録しないで進むと答えたら、完了の証拠から series.md への登録を外し、open の PR があることだけを確かめて 5 へ進む（理由を `## 工程の記録` の pr の行に書く。後の同期は `/series-sync` に任せる）
5. 満たしたら、作業単位を `pr: 済み` にし、adapter の「worker を解放する」で implement の worker を解放して checks の入口へ進む（ユーザーが操作した terminal は解放では閉じない。後始末は adapter）

## checks の工程

push の後に、CI の結果を coordinator が待ち、PR に既に付いた未解決の review thread（bot・人）を拾う。implement の後（`pr: 済み` の後）・fix の後（`fix: 済み` の後）・fix-light の後（`fix-light: 済み` の後）に入り、判定はこの節 1 か所に置く。worker を起動しないが時間がかかるので、状態は `checks: 確認中` を持つ。

1. **入口**（`pr: 済み`・`fix: 済み`・`fix-light: 済み` を確かめた時）
   - `## 工程の記録` に checks の行を足す: 起動時刻＝入口の時刻、起動時の HEAD＝`git -C <wt> rev-parse HEAD`、要約の先頭に `前: implement`・`前: fix`・`前: fix-light` のどれか。作業単位を `checks: 確認中` にする
   - 前の `tmp/checks.md` があれば `tmp/checks.archived-<日時>.md` に移す（triage の fixes.md と同じ暫定。下の「工程の境目での `tmp/` の退避」）
   - `前: fix` なら意味のカードを書き直す（`./meaning-card.md`。`round: fix-<巡>`。`前: fix-light` では書き直さない: 下の「軽い fix」）。HTML は html-view に `--no-open` を付けて作り（開かない）、パスを状態の表と受信箱に出す。書き直しで (d)(e) が前のカードから変わったら、PR 本文の「前提」の項目とケースの動作確認の項目を、下の「PR 本文の更新」の手順で書き換える（実装に即した記述なので coordinator が書く。`/create-pr` は implement の時点のカードを写したきりのため）
   - bot（Greptile など）を PR へのコメントで起動しない。checks は fix の巡ごとに入るので、起動すると巡の数だけ bot の課金が発生するため。bot が自動でレビューしていれば、その指摘を 3 で拾う
   - `## 運用の約束` に dispatch する workflow があれば、workflow ごとに `gh workflow run <ファイル名> --ref <ブランチ> --repo <段のリポジトリ>` を打ち、`gh api repos/<owner>/<repo>/actions/workflows/<ファイル名> --jq .name` で表示名を引いて checks の行の要約に控える（`gh pr checks` の `workflow` は表示名で、運用の約束に書くのはファイル名のため）
2. **確かめる時**: pr の工程の 3 と同じ（出来事を 1 つ処理するたび・時間切れのたび・worker が 0 体でターンを終える前とユーザーの返事が来るたび。SKILL.md の 4）。判定が済むまで毎回 3〜4 を当てる
3. **判定**: 次を集め、全部そろったら判定する
   - **PR のチェック**: `gh pr checks <PR> --repo <段のリポジトリ> --json name,bucket,workflow,event,link`（`--required` を付けない全件）。pending・fail でも rc=0 で JSON を返す。**チェックが 0 件のときは rc=1 で JSON を出さず、標準エラーに `no checks reported` と出す**ので、それを 0 件とする。それ以外の rc≠0 は取得の失敗で、判定せず次の確かめる時にやり直す。dispatch する workflow の表示名と同じで `event` が `pull_request` のチェックは除く（その workflow は dispatch の run を正にする）
   - **dispatch の run**: workflow ごとに `gh run list --repo <段のリポジトリ> --workflow <ファイル名> --branch <ブランチ> --event workflow_dispatch --commit <checks の行の HEAD> --json databaseId,status,conclusion`。run id を checks の行の要約に控える
   - **review thread**: 結果を待たない。判定の時点で、PR の未解決の review thread を、bot・人を問わず全件取る（取り方は下の「review thread の取り方」の query だけを使う。返信・resolve はしない。bot への返信も bot の課金にかかるため。返信は人が `/review-comments` で行う）。thread が無ければ 0 件で、thread の分は判定を止めない。取った thread を次のとおり分ける（bot は、`comments.nodes[0].author.login` の末尾の `[bot]` を除いたものが、`## 運用の約束` の bot のアカウントの末尾の `[bot]` を除いたものと一致する thread だけ。GraphQL の login は bot でも `[bot]` を付けない（REST だけが付ける）ので、除いて比べる。それ以外の login は人として扱う。`author` が null（退会したユーザー）なら人で、login は `ghost` と書く。`__typename` では判定しない（運用の約束に無い bot まで P0/P1 の判定に入るため））
     - **bot の P0・P1**（重大度は `## 運用の約束` の書式で読む）→ 指摘（判定の表の fail の行）。ただし**直した後も残る thread** は指摘にせず、`## 参考` に「直した後も未解決（<判断を書いた工程と時刻>）」の印で並べる。直した後も残る thread とは、その作業単位の `## 工程の記録` の `### thread の判断`（`./state-format.md`）にその URL で `直す` があり、その行の判断の時点の HEAD から今の HEAD までの第 1 親の鎖に、thread の path に触れた merge 以外のコミットがあるもの（`git -C <wt> log --first-parent --no-merges --format=%H <判断の時点の HEAD>..HEAD -- <thread の path>` が空でない。path を見ないと、別のファイルを直したコミットで直っていない P0/P1 が降格する）。path に触れたコミットが無ければ（別のファイルだけを直した・直す worker がコミットを作らず base の取り込みだけが入ったなど）指摘のまま。`git -C <wt> merge-base --is-ancestor <判断の時点の HEAD> HEAD` が失敗する（強制の push で履歴を書き換えた・sha の写し間違い）か、log のコマンドが失敗したときも指摘のまま（直したと言えない側に倒す）。同じ URL に行が 2 つ以上あれば最後の行で判定し、最後の行が `直す` のときだけ直した後も残る thread になりうる（最後が `直さない`・`後の段で配線される` なら、直した後も残る thread ではない。`./state-format.md` の thread の判断と同じ読み方）。同じファイルの別箇所だけを直したコミットでもこの条件は成り立つので、ここで降格した thread は SKILL.md の 4 の「`完了` にする前」で 1 回だけユーザーに見せる。また、同じ URL の最後の判断の行が `直さない（K-<n>）` か `後の段で配線される` の thread と、`## 直さないと決めた指摘` の出どころにその URL があって判断の行が無い thread も（仕分け済みの判定と同じ 2 か所を見る）、指摘にせず、`## 参考` に「直さないと決めた（K-<n>）」か「後の段（<段名>）」の印で並べる（ユーザーか triage が仕分け済みの判断を、checks のたびに指摘へ戻して③で聞き直したり、fix-light で③なしに直したりしないため。checks の指摘を既決の照合に掛けないのは、判断の行の無い新しい指摘の話）
     - **それ以外**（bot の P2 以下・重大度の無い bot の thread・人のレビュアー）→ 指摘にせず、`tmp/checks.md` の `## 参考` に 1 thread 1 行で並べる。判定の表には当てない（checks の完了を止めない）。仕分けは triage（SKILL.md の 5）と `完了` にする前（SKILL.md の 4）が行う
   - 判定の表: **上から当て、最初に当たった行で決める**。チェックが全件で 0 件で、dispatch する workflow も無いときは、CI の分は fail・pending が無いとみなし、bot だけで表を当てる

     | 状況 | 次 |
     |------|----|
     | dispatch の run が入口から 5 分たっても見つからない | ③（「dispatch し直す／飛ばす」）。ほかが pending でも先に聞く（PR のチェックは 40 分を超えて pending でありうるので、待つ行を先に置くと 5 分の判定に届かない） |
     | dispatch の対の無い workflow の必須チェック（`gh pr checks <PR> --repo <R> --required --json name,bucket,workflow`）が 1 件以上あり、その全部が `skipping` | ③（必須チェックが 0 件ならこの行に当てない。CI が動いていない。「dispatch する workflow を運用の約束に足すか／飛ばすか」） |
     | pending のチェック・終わっていない dispatch の run・まだ見つからない dispatch の run（入口から 5 分未満）がある | 待つ（下の 4 の上限まで）。まだ見つからない run をここに入れないと、5 分未満でほかが全部済んだときに最後の行に落ちる |
     | fail のチェック・失敗した dispatch の run（必須でないものも含む）・bot の未解決の P0/P1（直した後も残る thread と、最後の判断が直さない・後の段の thread を除く）がある | 1 指摘 1 行で `tmp/checks.md` に書いて 5 へ |
     | 上のどれにも当たらない | `tmp/checks.md` を「指摘なし」で書いて 5 へ |

4. **上限**: 入口の時刻から `## 運用の約束` の「checks の上限」（既定 45 分）を超えても pending が終わらないなら、③で「待つ（もう 1 回の上限）／失敗として扱う／飛ばす」を聞く。この③は 1 回に 1 つだけ立てる（`未回答` の間は立て直さない）。checks の③は、作業単位を `checks: 判断待ち` にする
   - checks の③の答えごとの書き方と次（どれも checks の行の要約に答えと `Q-<n>` を書く）:
     - **待つ**: `checks: 確認中` に戻し、checks の行の要約に「上限の延長: <答えた時刻>」を書く（上限はその時刻から数える）
     - **失敗として扱う**: `tmp/checks.md` に、判明済みの指摘（表の fail の行に当たるもの）を書いたうえで、未完了のチェック・run を 1 行ずつ「時間切れ」として足し、5 へ（triage・recheck の 4 が指摘として読む。判明済みの指摘を落とすと、CI の fail が入力から消える）
     - **飛ばす**: `tmp/checks.md` の本文を `飛ばした（③ Q-<n>）: <理由>` の 1 行にして（frontmatter の `head` は書く。再開の推定で checks をやり直さないため）5 へ。triage・recheck は指摘 0 件として読む
     - **dispatch し直す**: 入口の dispatch をやり直し、5 分の数え始めを今にする（checks の行の要約に「dispatch し直した: <時刻>」を書く）
     - **dispatch する workflow を運用の約束に足す**: ③の (ii) の答えとして `## 運用の約束` を書き直し、入口の dispatch からやり直す
   - 「飛ばす」「失敗として扱う」で進めた作業単位は、SKILL.md の 7 の 1 の報告に「CI を見ずに進めた」として出す
5. **済んだら**: 作業単位を `checks: 済み` にし、checks の行の要約に判定（指摘の件数・参考の件数・run id）を書く。次は `前:` で決まる（SKILL.md の 3 から再開したときも、ここを通る）
   - `前: implement` → review の起動へ（SKILL.md の 3）
   - `前: fix` → 下の「取り込みだけの判定」を当て、checks の行の要約に「取り込みだけ: はい」か「取り込みだけ: いいえ（<満たさなかった条件の番号> | コマンドの失敗: <コマンド> | git <版>）」を書く。取り込みだけでなければ recheck の起動へ（SKILL.md の 3）。取り込みだけなら recheck を起動せず（code-review に見せる自前の差分が無い）、`## 工程の記録` に recheck の行を足して「飛ばした（取り込みだけ）」と書く（同じ checks の行の後に `飛ばした` の recheck の行が既にあれば足さない。再開で二重にしない）。続けて下の「fix が新しいコミットを作らなかったとき」の③に入る。fix は直す指摘が 1 件以上あるときだけ入る（triage の直す・`完了` にする前で直すと答えた）ので、取り込みだけは、直す指摘に対応する自前のコミットが無いことを意味する。問いは「fix のコミットは base の取り込みだけで、直す指摘 <n> 件（`tmp/fixes.md`）に対応する自前のコミットが無い」。`tmp/checks.md` に指摘があれば、同じ③に 1 段目として並べる。「軽い fix」には入らない（直す指摘が直っていないかもしれず、checks の指摘だけを直す fix-light の範囲を超える）
   - `前: fix-light` → 下の「軽い fix」の 6

   **取り込みだけの判定**: fix のコミットが base の取り込み（merge）だけで、code-review に見せる自前の差分が無いかを見る。`<基準>` は fix の工程の基準の HEAD。次を全部満たすときだけ取り込みだけとする。1 つでも満たさない・コマンドが失敗する・git が 2.36 未満で `--remerge-diff` が使えないときは、取り込みだけでないとする（recheck を回す側に倒す）
   1. `git -C <wt> merge-base --is-ancestor <基準> HEAD` が成功する（rebase・強制の push で履歴を書き換えていない。worker は強制の push をしないので、書き換わるのはユーザーの④の後だけ。patch-id での同値の判定はしない）
   2. `git -C <wt> log --first-parent --no-merges --format=%H <基準>..HEAD` が空（第 1 親の鎖に merge 以外の自前のコミットが無い。`--first-parent` を付けないと、取り込んだ base 側のコミットまで並ぶ）
   3. `git -C <wt> log --first-parent --merges --format=%H <基準>..HEAD` が 1 件以上で、その各 merge `<M>` で `git -C <wt> show --remerge-diff --format= <M>` の出力が空（衝突の解決や手の変更を merge に混ぜていない。merge の中の手の変更は 2 の `--no-merges` に出ない。衝突を解いた merge は `remerge CONFLICT` が出るので、常に取り込みだけでない）。各 merge の親は 2 つ（`git -C <wt> rev-list --parents -n1 <M>` の語が 3 つ）であること。octopus merge は `--remerge-diff` の対象外なので、取り込みだけでないとする
   4. 3 の各 merge の 2 番目の親が段の base の祖先: `git -C <wt> fetch origin` の後に `git -C <wt> merge-base --is-ancestor <M>^2 origin/<base>` が成功する。`<base>` は series.md のこの段の base（別の段を指すなら、その段のブランチ。push の手順 1 と同じ引き方）

`tmp/checks.md` の書式（書き手は coordinator。implement の後は triage が、fix・fix-light の後は recheck の 4 と「軽い fix」の条件が読む。`## 参考` は triage と `完了` にする前が読む）:

<!-- tmp-frontmatter: tmp/checks.md -->
```markdown
---
type: Checks
title: <段名> の checks（<前: implement | 前: fix | 前: fix-light>）
description: CI の失敗と bot の P0/P1 の一覧（<件数> 件）・参考 <件数> 件
status: stable
head: <checks の行の HEAD>
---
# checks の指摘

- <CI <workflow>/<check> <link> | bot <アカウント> <thread の URL>>: <要旨>

## 参考

- <bot <アカウント> <重大度> | 人 <login>> <thread の URL> <path>[:<line か originalLine>]（<outdated | 直した後も未解決（<判断を書いた工程と時刻>） | 直さないと決めた（K-<n>） | 後の段（<段名>）>）: <要旨>
```

指摘が無ければ `# checks の指摘` の下を「指摘なし」の 1 行に、参考が無ければ `## 参考` の下を「なし」にする。括弧の付記は、outdated・直した後も未解決・直さないと決めた・後の段のときだけ書く。2 つ当たるとき（outdated で直さないと決めたなど）は `・` で並べて両方書く。`## 参考` の無い `tmp/checks.md`（checks の③で「飛ばす」と答えた・この節より前の形）は、参考 0 件として読む（仕分けていない thread は `完了` にする前の取り直しで拾う）。

### review thread の取り方

checks の 3 と `完了` にする前（SKILL.md の 4）が使う。返信・resolve の mutation は打たない。

```bash
gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { id isResolved isOutdated path line originalLine
          comments(first: 1) { nodes { author { login } body url } } }
      }
    }
  }
}' -f owner=<owner> -f repo=<repo> -F number=<PR>
```

- `hasNextPage` が true なら `-f after=<endCursor>` を足して繰り返し、最後の頁まで取る（`first: 100` の 1 回だけだと、101 件目以降を黙って落とす）
- `isResolved: true` は除く。`isOutdated: true` は除かずに、`## 参考` の行に「outdated」と付記する（行が動いただけで直っていないことがある）。outdated の thread は `line` が null になりうるので、そのときは `originalLine` を書く。`line` と `originalLine` がどちらも null（ファイル単位のコメント）なら `<path>` だけを書く
- 書き手は `comments.nodes[0].author.login`、thread の URL は `comments.nodes[0].url`、重大度は bot の body から `## 運用の約束` の書式で読む
- rc≠0・応答に `errors` があるときは取得の失敗で、判定せず次の確かめる時にやり直す（0 件と取り違えない）

照合の残差: dispatch の run は、ブランチの先頭を base とマージせずに検査する（PR の run は base とのマージを検査する）。ドラフトを解除すると PR の run が改めて走るので、マージの前の最終の確認はそちらになる。

## PR 本文の更新

coordinator が PR 本文を書くときの手順（何を書くかの仕分けは SKILL.md の 4 の完了報告の 3）。`<PR>` は「起動の前の確認」の review・fix・fix-light・recheck と同じく引く。`gh pr edit` は使わない（環境によって失敗する）。

1. 書く直前に `gh pr view <PR> --repo <段のリポジトリ> --json body` で今の本文を取り直し、ファイルに残す（ユーザーや別の worktree が書き換えていることがある。古い本文に書き足すと、その変更を消す。残したファイルは消えたときの復元にも使う）
2. 書く主張を、コミットの差分（`git -C <wt> log`・`git -C <wt> diff`）で裏取りする。裏が取れない主張は書かない
3. 取り直した本文に書き足したもの（既存の行のチェックを付ける変更を含む）をファイルに置く。PATCH の直前に 1 と同じコマンドでもう一度取り直し、1 で残した本文と比べる。違えば 1 からやり直す（2 回続けば③としてユーザーに回す。2 の裏取りの間に本文が書き換わると、PATCH がその変更を消し、4 の読み直しでは気づけない）。同じなら `gh api -X PATCH repos/<owner>/<repo>/pulls/<PR> -F body=@<ファイル>` で書く
4. 1 と同じコマンドで読み直し、書いた本文と、末尾の空白・改行を除いて一致することを確かめる。一致しなければ③としてユーザーに回す

`stack-pr-submit` の再実行は既存の PR の本文を上書きしない（タイトルだけを更新する）ので、ここで書き足した分は残る。

### 節「意図した挙動・受け入れた残差」

状態ファイルの `## 直さないと決めた指摘` に行を足したら、上の 1〜4 の手順で、その作業単位の PR 本文の節「意図した挙動・受け入れた残差」に 1 行足し、その行の「PR 本文」の列を `済み` にする。ただし、出どころが `推奨で進めた`（③の 3 段目）で「PR 本文」が `未（推奨）` の行は書かない。ユーザーが推奨どおりと確かめて `未` になった時点で書く（SKILL.md の 4 の「答えが出たら」。確かめていない判断を、人のレビュアーへの説明として残さないため）。人のレビュアーと外部のレビューの bot に、同じ指摘を繰り返させないための説明である（組み込みの `code-review` が PR 本文を読むかは確かめていないので、上の recheck の照合の代わりにはしない）。

- 節が無ければ、本文の末尾の署名（`🤖 Generated with` の行など）の前に `## 意図した挙動・受け入れた残差` を作る
- 1 行に書くのは、どのコードの何についてか（`path` を含む）と、直さない理由だけ。状態ファイルの番号（`Q-<n>`・`K-<n>`）は書かない（PR の読者には意味が無い）
- 直さないという判断は③か triage で済んでいるので、ここで書くことに改めて③は要らない
- PR がまだ無い段（design・plan-lgtm の③で決まったものなど）は、pr の工程の後に、「PR 本文」が `未` の行をまとめて書く

## 仕分け（triage）が 0 件のとき

直すものが 0 件なら fix と recheck を飛ばす（`完了` にする前に、SKILL.md の 4 の「`完了` にする前」を当てる。下の 2 つの節と recheck の工程の `完了` も同じ）。初回の push は implement の工程で済み、PR もあり、新しいコミットも無いので push の担い手は要らない。coordinator は `git -C <wt> rev-parse HEAD` と `git -C <wt> rev-parse @{u}` の一致だけを確かめて作業単位を `完了` にし、fix と recheck の工程の記録に「飛ばした（0 件）」と書く。一致しなければ③としてユーザーに回す（coordinator は push しない）。

## fix が新しいコミットを作らなかったとき

fix の worker が全項目を対応不要と判断して、新しいコミット無しで成功を報告したら、fix の worker を adapter の「worker を解放する」で解放し（完了報告は受け入れたので）、HEAD と `@{u}` の一致だけを確かめ、③で「全項目を対応不要と判断した。完了にしてよいか」を確かめる。完了にしてよいと答えたら、fix の工程の記録に「新しいコミット無し」と書き、checks と recheck を飛ばして `完了` にする（新しい差分が無い。HEAD が変わらないので implement の後の checks の結果がそのまま当たり、dispatch し直すと CI の時間を無駄にする）。`fix: 済み` から checks の入口へ進むのは、fix の完了の証拠（新しいコミットと push）を満たしたときだけ。よくないと答えたら、同じ問いの選択肢として「fix を起動し直す（試行の 2 回目として数え、成功の報告の後なので「worker の起動」で新しく起動する）か、手で直す（`対象外`）か」を 1 回で決める。HEAD と `@{u}` が一致しなければ、③で一致しない旨も示す（coordinator は push しない）。

checks の 5 の取り込みだけ（fix のコミットが base の merge だけ）も、この③に入る。違いは 3 点: fix の worker は `fix: 済み` で解放済みなので解放の手順は当てない。「完了にしてよい」と答えたら、checks は済んでいるので SKILL.md の 4 の「`完了` にする前」の後に `完了` にする（その確認で③を立てるときも、状態は `fix: 判断待ち` のままにする）。fix の行には「新しいコミット無し」ではなく「取り込みだけ（③ `Q-<n>` で完了）」と書く（merge のコミットはある）。

どちらの経路でも、次を同じく当てる。

- この③の間は、作業単位を `fix: 判断待ち` にする。答えは、この節に従って処理する
- 「完了にしてよい」は直さない判断なので、`tmp/fixes.md` の直す指摘を `## 直さないと決めた指摘` に 1 指摘 1 行で足す（出どころは指摘の元のもの — `review`・`recheck`・`外部（<アカウントか login>）<thread の URL>`、後の段から届いた指摘はその元 — で、`fix` という出どころは作らない。根拠は `Q-<n>`）。理由の欄には、新しいコミット無しの経路では worker の完了報告の対応不要の理由を、取り込みだけの経路では「base の取り込みで足りるとユーザーが判断（`Q-<n>`）」を写す（coordinator が理由を作文しない）。足したら「PR 本文の更新」の節「意図した挙動・受け入れた残差」に書く
- 同じ③に並べた checks の指摘のうち thread のもの（bot の P0/P1）は、答えを `## 工程の記録` の `### thread の判断` にラベル `fix（取り込みだけ）` で書き、「直さない」なら `## 直さないと決めた指摘` にも足す（書かないと、`完了` にする前の取り直しで同じ thread をもう一度聞く）。thread でない CI の失敗を残して「完了にしてよい」と答えたら、SKILL.md の 7 の 1 の報告の「CI を見ずに進めた」に出す。「fix を起動し直す」なら、checks の指摘も `tmp/fixes.md` に足して起動する
- 「fix を起動し直す」で試行が上限の 2 回を超えるときは、この③の答えをもって 1 回だけ足す（工程の記録の試行の番号は前と続けて数える）

fix-light がコミットを作らなかったときは、下の「軽い fix」の 7 に従う（checks の指摘が残るので、`完了` にしてよいかは聞かない）。

## recheck の工程

fix の後に、PR を組み込みの `code-review` で見直す。組み込みの `code-review` には、直さないと決めた指摘を渡す口が無い（引数は強さ・対象と出力の指定だけ）。判断を説明するコードのコメントがあっても、同じ指摘が出ることを観測した。そこで、既に直さないと決めた指摘との照合は、受け取る側（worker と coordinator）で行う（下の 3・4）。契約は 2026-10-21 にドラフトの PR を対象に `low` で 1 回実行して確かめた: ドラフトの PR を対象にできる・`--comment` を付けなければ PR にコメントもレビューも付かない・結果は文章で呼び出し元に返る（worker が転記できる）。

1. **強さ**: coordinator が起動の前に `git -C <wt> diff --shortstat <fix の工程の基準の HEAD>..HEAD` の挿入と削除の合計で決め、spec に書く（worker に規模を判断させない。判断が割れるため）。100 行未満なら `low`、100〜399 行なら `medium`、400 行以上なら `high`。しきい値は暫定（`low` は、実行できるコードの無い差分では本文を読まずに終えることがある。Markdown だけの PR で観測した）
   - **上限**: fix の 2 巡目（下の「fix の 2 巡目」）の後と、fix-light の後に回す recheck は、行数で `high` になっても `medium` にする（`high` は新規の指摘を多く出し、巡が収束しない）
   - **fix-light の後**: 行数は `git diff --shortstat` ではなく、直前の fix-light の工程の基準の HEAD からの自前の差分（下の「軽い fix」の 6 の数え方）で数える。上の `<fix の工程の基準の HEAD>..HEAD` は fix の後の recheck だけに当てる（fix-light の後に fix の基準を使うと、fix の分まで数えて強さが上がる）
2. **起動する skill**: Claude Code の組み込みの `code-review`（Skill ツールの名前は `code-review`。plugin の skill は `<plugin>:code-review` の名前空間付きで並ぶので、それを使わない。どちらが起動したか区別できなければ、失敗で報告する）に、強さと PR 番号を渡す。`--comment` は付けない（付けると PR に投稿する）。対象に PR 番号を渡すのは、fix のコミットが push 済みで、作業ツリーの差分が空のため。PR 全体を見る
3. **出力**: worker が `tmp/code-review.md` を下の雛形で書く。frontmatter の直後の本文の 1 行目に `対象: PR #<番号>・強さ: <強さ>`、2 行目に `指摘: <件数> 件（新規 <n>・既決 <m>）`、続けて指摘を書く（`code-review` の出力を転記する）。frontmatter を先頭に置くのは、`tmp/` の md に frontmatter を求める hook が、無いファイルの書き込みを止めるため。前の試行のファイルは上書きしてよい

<!-- tmp-frontmatter: tmp/code-review.md -->
```markdown
---
type: Code Review
title: <段名> の recheck（PR #<番号>）
description: code-review の指摘 <件数> 件（新規 <n>・既決 <m>）
status: stable
---
対象: PR #<番号>・強さ: <強さ>
指摘: <件数> 件（新規 <n>・既決 <m>）

- [新規] <指摘>
- [既決 K-<n>] <指摘>（同じ点: <1 文>）
```

   - 各指摘の頭に `[新規]` か `[既決 K-<n>]` を付ける。照合の相手は spec の「これまでに直さないと決めた指摘」（`./worker-spec.md`）。既決とするのは、写された指摘と同じコードの同じ挙動を指すときだけ。言い回しが似ているだけ・条件や経路が違う・迷ったときは新規にする（安全側）。既決の指摘には、どの点が同じかを 1 文添える
4. **指摘が 1 件以上か、`tmp/checks.md` に指摘があるとき**: 直前の checks（`前: fix` か `前: fix-light`）の `tmp/checks.md` の `# checks の指摘` に行があれば、code-review が 0 件でも直接 `完了` にせず、この 4 に入る（CI が赤・bot の P0/P1 が残るまま `完了` にしないため）。code-review が 0 件で checks.md も「指摘なし」のときだけ、直接 `完了` にする。checks の指摘は既決の照合に掛けない（CI の失敗と bot の P0/P1 は毎回新しい）。coordinator は、まず `[既決]` の印をコードで裏取りする（印は worker の主張。写した指摘と同じ箇所・同じ挙動かを確かめる）。裏取りで既決と言えなかったものは新規に戻す
   - **新規が 0 件**（全件が既決で、裏取りも済んだ。checks の指摘も無い）: ③を立てずに `完了` にする。ユーザーが一度決めたことを同じ答えで聞き直すだけになるため。`## 工程の記録` の要約に既決の番号を並べ、完了の報告にも既決の一覧（番号と要旨）を出す
   - **code-review の新規が 0 件で checks の指摘がある**: 下の「軽い fix」の 2 の入る条件を当てる。満たせば③を立てずに fix-light に入る。満たさなければ、下の「新規が 1 件以上」と同じく③に入れる（checks の指摘は 1 段目）
   - **code-review の新規が 1 件以上**（checks の指摘があれば一緒に③に入れる）: 新規を③の 3 段（SKILL.md の 4「質問」）で仕分ける。1 段目に当たるものを③の表にまとめ（指摘・推奨: 直す / 直さない）、ユーザーに回す。推奨は下の「推奨の決め方」で決める。checks の指摘は、推奨が直す・直さないのどちらでも常に 1 段目に入れる（3 段目で推奨どおり進めると、CI が赤のままであることをユーザーが知らないまま下の分岐で `完了` になる。1 段目で聞いても「1 件でも直す」は `完了` と④で、CI を直すのは④の先になる。自動で fix の 2 巡目を回さない規則は変えない）。2 段目は答えと引用を `## 工程の記録` に書き（「直さない」と答えたものは、引用元が `K-<n>` でなければ `## 直さないと決めた指摘` にも足す。SKILL.md の 4「質問」の 2 段目）、3 段目は推奨で決めて `## ユーザーへの依頼` に `推奨で進めた（<日付>）` で記録する（`./state-format.md`）。1 段目が 0 件なら、2・3 段目の答えで下の分岐に進む。既決は表の下に「参考: 既決 <m> 件（K-…）」の 1 行で添える。自動で fix の 2 巡目は回さない（上限を文で決める。`../../plan-lgtm/SKILL.md:L69` と同じ理由）。答えの後:
   - **推奨の決め方**: 指摘が次のどれかに当たれば「直す」、どれにも当たらなければ「直さない」を推奨にする（3 段の当て方は変えない。3 段目で推奨どおり進めるときも、この推奨を使う）。③の表の推奨の理由に、当たった条件の記号（(a)〜(c2)）か「どれにも当たらない」を書く（推奨の割れを後から追うため）
     - (a) checks の指摘（`tmp/checks.md` の `# checks の指摘` の行。CI の失敗・bot の P0/P1）。`## 参考` の thread は含めない（含めると P2 以下の多くが直すになり、巡が増える）
     - (b) 戻せない物に触れる（SKILL.md の 4「質問」の 1 段目の (iv) の列挙と同じ）
     - (c1) 指摘の path が、この段の変更ファイル（`<wt>/tmp/plan.md` のファイル変更マップ。無ければ横断計画のこの段のステップの変更対象）に載っている
     - (c2) 直さないと、段をまたぐ契約（横断計画に書いた段の分担・段の間の I/F）が崩れる
   - 全部直さない → 理由を `## 工程の記録` に書き、新規の指摘を `## 直さないと決めた指摘` に足して（`./state-format.md`。3 段目の推奨で「直さない」にしたものは、出どころ `推奨で進めた Q-<n>`・PR 本文 `未（推奨）` で足す）`完了`
   - 1 件でも直す → `完了` にし、直す指摘を `## ユーザーへの依頼` に④（`R-<n>`。どの worktree で何を直すか）で残す。同じ答えで直さないとした指摘は `## 直さないと決めた指摘` に足す（3 段目の推奨で「直さない」にしたものは、上と同じく印を付けて足す）
   - どちらも `対象外` は使わない（`対象外` は工程を回さない作業単位の意味。`./state-format.md` の状態名）
   - checks の指摘のうち thread のもの（bot の P0/P1）は、答えの後に `## 工程の記録` の `### thread の判断` に、ラベル `recheck（<試行>）`（recheck を飛ばしたときは `recheck（飛ばした）`。recheck の行が無い経路 — fix-light がコミットを作らなかったとき — は `fix-light（L<回>）`）で書く（`./state-format.md`。書かないと、`完了` にする前の取り直しで同じ thread をもう一度聞く）

## 軽い fix（fix-light）

recheck の後などに残った CI の失敗・bot の P0/P1 だけを、③を立てずに直す工程（3 シリーズで、毎回ユーザーが同じく「直す」と答えていた小さな修正）。plan-lgtm を通さず、意味のカードも書き直さない（CI・bot の指摘の修正は意味を変えない: `./meaning-card.md`）。直すと決めて回すので、checks が残る限り CI が赤のまま `完了` にはならない。範囲を外れたら事後の実測で recheck に戻す（下の 6）。

1. **工程**: 工程の表の fix-light の行。`/implement` は LGTM の計画を前提にしないので、plan-lgtm を挟まずに `/fix` の fix-plan.md をそのまま渡す
2. **入る条件**: coordinator が次を全部満たすかを機械的に判定し、満たすときだけ入る。1 つでも外れたら、今までどおり「recheck の工程」の 4 の③（checks の指摘は 1 段目）
   - 直す対象が `tmp/checks.md` の `# checks の指摘` の行（CI の失敗・bot の P0/P1）だけで、code-review の新規（裏取りの後）が 0 件。recheck を飛ばした経路（下の 6）は、code-review の新規 0 件として扱う。`## 参考` の thread は対象にしない
   - その作業単位の fix-light の回数（`## 工程の記録` の fix-light の回の数。下の 7 のコミットの無かった回も数える）が 2 未満。fix の巡の上限と、`完了` にする前から fix に入る 1 回には数えない
   - 入口は 2 つ: 「recheck の工程」の 4（code-review の新規 0 件で checks の指摘あり）、下の 6（`前: fix-light` の checks で指摘あり）。checks の 5 の取り込みだけは入口にしない（「fix が新しいコミットを作らなかったとき」の③）
3. **起動の前**: 「起動の前の確認」を当てる（PR が open でなければ起動せず③）
4. **起動**: coordinator が checks の指摘を `<wt>/tmp/fixes.md` に書く（既にあれば `tmp/fixes.archived-<日時>.md` に移してから。triage と同じ暫定）。thread の指摘は、`## 工程の記録` の `### thread の判断` にラベル `fix-light（L<回>）` で `直す` と書く（回の 1 回目の試行の起動の時だけ。`./state-format.md`）。spec（`./worker-spec.md`）の Change には、起動する skill と push の手順に加えて次を書く
   - `tmp/fix-plan.md` の上書きを問われたら、確認せず上書きを選ぶ（fix が旧版を snapshot で残す: `../../fix/SKILL.md:L71`。SKILL.md の 4「質問」の 2 段目の例と同じ規則）
   - fix-plan は `tmp/fixes.md` の項目だけで作る。`tmp/review/unified.md` の指摘は対象にしない（triage で仕分け済み。`/fix` は unified.md があれば併せて読む: `../../fix/SKILL.md:L41`）
   - 既に直さないと決めた指摘（spec の「これまでに直さないと決めた指摘」）の挙動を変える必要があれば、変えずに質問で coordinator に聞く

   spec の「これまでに直さないと決めた指摘」の欄は、recheck と同じ規則で写す（Change に書く文ではない。`./worker-spec.md` のその欄）。fix-light の worker には、その挙動を変えないための制約になる
5. **回と試行**: `## 工程の記録` の試行の欄は `L<回>-<試行>`（例: `L1-1`・`L2-1`）。工程の基準の HEAD は回ごとの 1 回目の試行で取り、試行の上限 2 回も回ごと
6. **済んだら**（`前: fix-light` の checks が済んだ時。checks の 5）: coordinator が事後に規模と範囲を実測する（worker の見積りは使わない。割れるため）。`<基準>` は直前の fix-light の工程の基準の HEAD
   - 自前の差分: `git -C <wt> log --first-parent --no-merges --shortstat --format= <基準>..HEAD` の挿入と削除の合計（コミットごとの合計で、正味の差分ではない。数えすぎは recheck を回す側に倒れる）
   - 変えたファイル: `git -C <wt> log --first-parent --no-merges --name-only --format= <基準>..HEAD`
   - 第 1 親の鎖の上の merge（`git -C <wt> log --first-parent --merges --format=%H <基準>..HEAD`）の各々に、checks の 5 の取り込みだけの判定の 3（`--remerge-diff` が空）と 4（2 番目の親が base の祖先）を当てる（merge の中の手の変更は、上の 2 つの数に出ない）。merge が 0 件なら当てない
   - 自前の差分が 50 行未満、変えたファイルがすべてこの段の変更ファイル（「recheck の工程」の 4 の (c1) と同じ）に載っている、merge がすべて上の 2 条件を満たす → recheck を飛ばし、`## 工程の記録` に recheck の行を足して「飛ばした（fix-light の後・<行数> 行）」と書く（同じ checks の行の後に `飛ばした` の recheck の行が既にあれば足さない）。続けて `tmp/checks.md` の指摘なし → SKILL.md の 4 の「`完了` にする前」の後に `完了`／指摘あり → 2 の条件を当て直す（満たせば次の fix-light、満たさなければ「recheck の工程」の 4 の③。checks の指摘は 1 段目で、推奨は (a) の直す）
   - どれかを満たさない・コマンドが失敗する → recheck を起動する（強さは「recheck の工程」の 1 の fix-light の後の数え方で、上限 `medium`）
   - どちらでも、checks の行の要約に実測の値（行数・段の外のファイル・手の変更のある merge）を書く
7. **新しいコミットを作らなかったとき**: fix-light の worker が直す物が無いと判断し、新しいコミット無しで成功を報告したら、「fix が新しいコミットを作らなかったとき」と同じく worker を解放して HEAD と `@{u}` の一致を確かめ、checks の指摘を「recheck の工程」の 4 の③（1 段目）に回す（「fix-light が直す物が無いと判断した。残る checks の指摘をどうするか」）。この回も fix-light の回数に数える（`## 工程の記録` のその行の成否を「成功（新しいコミット無し）」にする）。checks の指摘が残っているので、③を飛ばして `完了` にしない。HEAD と `@{u}` が一致しなければ、③で一致しない旨も示す

## 失敗したとき

- 完了報告の「残り」に push の手順で止めた旨（「手順 1」〜「手順 4」）があり、証拠の不足が push だけ（工程の基準の HEAD から新しいコミットはある）なら、起動し直さずにユーザーに回す。原因が worker の外にあり、起動し直しても同じ理由で止まるため
  - どちらも、止めた worker は adapter の「worker を解放する」で解放する（起動し直すときは新しく起動する）
  - 手順 4（強制の push）→ `R-<n>`。作業単位を `ユーザーの操作待ち（強制の push）` にする。worker は解放済みで terminal は無いので、内容にはユーザーが自分の terminal で打つものを書く（worktree のパスと `git -C <wt> push --force-with-lease`）。ユーザーが打ったと伝えたとき、時間切れのたび、worker が 0 体でターンを終える前とユーザーの返事が来るたび（SKILL.md の 4）に、`@{u}` と HEAD の一致を確かめ、一致すれば `## 工程の記録` のその試行の行の成否を「成功（強制の push はユーザー）」で埋め（順序の判定はこの行を見る）、`R-<n>` を `済み`、作業単位を `<工程>: 済み` にする
  - 手順 1（前の段の取り込み）・手順 2（照合の不一致）・手順 3（upstream の向き）→ `Q-<n>`。作業単位を `<工程>: 判断待ち` にする。手順 1 で「取り込む」と答えたら、同じ工程を「worker の起動」で起動し直す（spec の Change に「前の段のブランチを取り込んでから push の手順を行う」と書く）。「取り込まない」なら、手順 1 を省いてよいかを同じ答えで決め、省くなら spec にそう書いて同じ形で起動し直す。手順 2・3 は、問いに不一致の中身（toplevel と Target・origin とリポジトリ・upstream の向き）を示し、ユーザーが直した（または spec の Target を直すと答えた）後に、同じ形で起動し直す。どちらも試行の回数に数えない（`## 工程の記録` には新しい行を足し、試行の欄に前と同じ番号と「（取り込みの後）」を書く。工程の基準の HEAD は書き換えない）
- plan-lgtm の worker が、ユーザーが再設計か中断を選んだことを失敗で報告したときは、再試行しない（「再設計で design に戻す」「plan-lgtm を中断で抜ける」）
- それ以外で、完了報告が失敗、または成功の報告でも完了の証拠を満たさないときは、同じ工程を 1 回だけ起動し直す。2 回目も失敗ならユーザーに回す（③として扱う）
  - 失敗の報告・止めた試行の後は、adapter の「工程の再試行」で起動し直す
  - 成功の報告で証拠を満たさないときは、その試行は成功として終わっていて再試行の対象にならないので、adapter の「worker を解放する」の後、「worker の起動」で新しく起動する（試行の回数は 2 回目として数える）
- 失敗を受け入れた worker の terminal は、起動し直す前に adapter の「worker を解放する」で片付ける（ユーザーが中を見たいと言ったときだけ「worker の terminal を残す」）。2 回目の失敗でユーザーに回すときも同じ
- 自動で 3 回以上は回さない。series-run はコードを持たず、上限の遵守はモデルの instruction-following に依存するので、上限を文で決めておく（`../../plan-lgtm/SKILL.md:L69` と同じ理由）
- 試行の数え方:
  - **起動そのものの失敗**（起動の応答が失敗・結果が不明）は、worker の失敗報告と分ける。試行の回数に数えず、adapter の「起動の失敗の扱い」に回す
  - **死んだ worker**（終了の積極的な証拠がある）は、adapter の「試行を止める」で止めてから扱う。トランスクリプトがあれば（作業を始めていた）、完了報告が失敗だったときと同じく試行の 1 回に数える（数えないと、毎回途中で死ぬ worker が上限なしに起動し直される）。トランスクリプトが無ければ（作業を始める前に死んだ）試行に数えずに 1 回だけ起動し直し、2 回続いたらユーザーに回す（続いた回数は `## 工程の記録` の成否の欄に「起動直後に死亡」と書いて数える。再開しても数が失われない）（ツールが起動の成功を返した後の死なので、ツール側の起動の失敗の上限には数えられない）

## fix の 2 巡目

SKILL.md の 4 の「`完了` にする前」で、後の段から届いた指摘か、未解決の review thread を直すと答えたときだけ、fix に入る（この確認から fix に入るのは作業単位ごとに 1 回だけ）。triage が 0 件で fix を飛ばしていたなら、これは fix の 1 巡目として扱い、巡を添えずに通常の fix の工程として回す。fix を既に回していたなら 2 巡目で、次のとおり扱う。

- 工程の基準の HEAD は、2 巡目の 1 回目の試行の起動時に取り直す（1 巡目のコミットを 2 巡目の成果と数えない。recheck の強さも 2 巡目の差分で決まり、上限は `medium`: 「recheck の工程」の 1）
- 試行の回数も 2 巡目で 1 から数え直す（上限の 2 回は巡ごと）。`## 工程の記録` の試行の欄には `2-1`・`2-2` のように巡を添える
- 2 巡目の fix の後も recheck を回す（`完了` の前の確認も同じく当てる。checks の 5 の取り込みだけの判定は 2 巡目にも当て、取り込みだけなら checks の 5 のとおり recheck を飛ばして③）。2 巡目の後に入り直す答えが出ても、3 巡目は回さない（SKILL.md の 4）

## 工程の境目での `tmp/` の退避（B6 の差し込み口）

同じ worktree で工程が進むと、後の工程の skill が前の工程の `tmp/` の成果物を上書きする（例: fix-lgtm-implement の中の review-plan が `tmp/plan-review.md` を作り直す）。工程の境目での `tmp/` の退避の規則は、`feat-tmp-okf-document` の決定に従う（未決）。

決まるまでは、plan-lgtm の工程の完了の証拠を確かめたときに、`tmp/plan-review.md` の `**総合判定**`・`**対象**`・更新時刻の 3 点を状態ファイルの `## 工程の記録` の要約の欄に写す（後の工程が同じファイルを上書きしても、判定の記録が残る。写す規則の正典はここ）。ファイルそのものは動かさない（退避の規則を先取りしないため）。triage が `tmp/fixes.md` を書く前に既存のものを `tmp/fixes.archived-<日時>.md` に移すのも、checks の入口で `tmp/checks.md` を `tmp/checks.archived-<日時>.md` に移すのも、この決定が出るまでの暫定である。
