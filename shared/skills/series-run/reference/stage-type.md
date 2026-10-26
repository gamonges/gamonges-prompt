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
| design | worker | `/design` → `/plan-lgtm` | `tmp/context.md`（series-init の引き継ぎ。`outline:`・`series:` を持つ） | `tmp/plan.md`・`tmp/plan-review.md` | 完了報告が成功、かつ `tmp/plan-review.md` の `**総合判定**` が LGTM・`**対象**` が `tmp/plan.md`・plan-review.md が plan.md より新しい（plan-lgtm と同じ 3 点）、かつ plan-review.md の更新時刻が試行の起動時刻より後（前の試行・既存の worktree の残骸で通さない） | implement |
| implement | worker | `/implement tmp/plan.md` → push（下の「push の手順」） | LGTM の `tmp/plan.md` | コミット・リモートのブランチ | 完了報告が成功、かつ `git -C <wt> log <工程の基準の HEAD>..HEAD` が空でなく、`git -C <wt> rev-parse @{u}` が HEAD と一致 | pr |
| pr | ユーザー（④） | `/create-pr` | リモートのブランチ（`/create-pr` は push の手順を持たず、`gh pr create --head <今のブランチ>` を打つだけ。`../../create-pr/SKILL.md:L231-239`） | open のドラフト PR | `gh pr list --repo <段のリポジトリ> --head <ブランチ> --state open` に PR があり、series.md の `## 段` のその段に PR が登録された。`<ブランチ>` は `git -C <wt> branch --show-current`（series.md のブランチ列は、この登録で初めて埋まる）。coordinator は別のリポジトリで動くことがあるので `--repo` を付ける | review |
| review | worker（claude に固定） | `/review` | 今のブランチに open の PR がある（`../../review/SKILL.md:L95-102`。無いと止まる） | `tmp/review/unified.md` | 完了報告が成功、かつ unified.md の更新時刻が試行の起動時刻より後（review はコミットを作らないので HEAD では判定できない。recheck のような件数の行は求めない。unified.md は review の skill が決まった書式で書き、件数のサマリーを持つため） | triage |
| triage | coordinator | — | unified.md・横断計画・series.md | `tmp/fixes.md`（`../../fix/reference/category-examples.md:L6-22` の形） | 指摘ごとの仕分け（直す / 後の段 / 直さない）を状態ファイルに記録した | fix（直すものが 0 件なら、下の「仕分け（triage）が 0 件のとき」） |
| fix | worker | `/fix-lgtm-implement tmp/fixes.md` → push（下の「push の手順」） | `tmp/fixes.md`（fix の実行条件。`../../fix-lgtm-implement/SKILL.md:L22`） | 追加のコミット・リモートのブランチ | implement と同じ（工程の基準の HEAD からの新しいコミットと、`@{u}` と HEAD の一致）。新しいコミットが無いときは、下の「fix が新しいコミットを作らなかったとき」 | recheck |
| recheck | worker（claude に固定） | `/code-review <強さ> <PR 番号>`（下の「recheck の工程」） | fix の完了の証拠（push 済み）と open の PR | `tmp/code-review.md` | 完了報告が成功、かつ `tmp/code-review.md` の更新時刻が試行の起動時刻より後、かつ 1 行目の対象と強さが spec と一致し、2 行目に `指摘: <件数> 件` がある（件数の行が無ければ、レビューできなかったとみなし、証拠を満たさない。0 件と取り違えない） | 完了（指摘が 1 件以上なら、下の「recheck の工程」の 4） |

- 前の工程の完了の証拠は、次の工程の入力（実行条件）を含む。implement の push が無いと `/create-pr` が作る PR の head が無く、pr の工程の open の PR が無いと `/review` が止まる
- review の worker を claude に固定するのは、Codex では `~/.agents/skills/review` に同名の別実装があると `tmp/review/unified.md` が作られないため（この repo の `README.md:L121`。実行時に読む必要は無い）。recheck を claude に固定するのは、組み込みの `code-review` が Claude Code にしか無いため。ほかの工程は claude を既定にし、状態ファイルの `## 運用の約束` で工程ごとに変えられる
- 1 つの worktree には同時に 1 体の worker だけを入れる。工程は `tmp/` の成果物を前の工程が書いて次の工程が読むので、並列にするのは worktree の間だけ

## 工程の基準の HEAD と、試行の起動時の HEAD・時刻

worker を起動する直前に、`git -C <wt> rev-parse HEAD` と起動時刻を、状態ファイルの `## 工程の記録` のその試行の行に書く（試行の起動時の HEAD・時刻）。その工程の 1 回目の試行では、同じ HEAD を「工程の基準の HEAD」にも書き、再試行・再開では書き換えない。

- implement・fix の「新しいコミット」は、工程の基準の HEAD から数える。前の試行がコミットした後に push だけで失敗したとき、再試行は前の試行のコミットを確かめて push だけを再開してよい（成果は工程の単位で評価する）。worker は段の型を読まず、工程の再試行は spec を差し替えないので、このことは 1 回目の spec の Change に最初から書いておく（`./worker-spec.md` の埋め方）
- design・review・recheck の「起動時刻より後」は、試行の起動時刻を使う（前の試行の成果物を今回の成果と取り違えないため）。前の試行の正しい成果を捨てないよう、design の 1 回目の spec の Change には「前の試行の `tmp/plan.md` が残っていれば、それを入力に `/plan-lgtm` だけを回し直してよい」と書く（判定を作り直すので、plan-review.md の更新時刻が今回の試行の後になる。工程の再試行は spec を差し替えないので、1 回目から書く）

## push の手順

implement と fix の worker が使う。初回かどうかの判定をここ 1 か所に置く。「残り」に「手順 N」と書くのは、下の手順が push を止めたときだけ。push のコマンドそのものが通信の障害などで失敗したときは、番号を書かずに失敗で報告する（coordinator は通常の失敗として再試行する）。照合に使う値（worktree のパスと段のリポジトリ）は、coordinator が spec の Target に書く。series.md のブランチ列と worktree 列は照合に使わない（ブランチ列は `/create-pr` の register が埋めるまで空。worktree 列は handoff に回った段では、`/create-pr` の register が埋めるまで空。`../../series-init/SKILL.md` の「下書き → check → write」）。

1. **前の段の取り込みの確認**: 自分の段の base が、シリーズの別の段を指す（指す先の段のブランチ名か、`段 <名> に積む` の形）ときだけ行う。指す段のブランチは、その段の worktree で `git -C <その wt> branch --show-current` で引く（coordinator が spec の Change に書く）。`git -C <wt> fetch origin` の後に `git -C <wt> log HEAD..origin/<そのブランチ>` が空であることを確かめる。空でなければ push せず、完了報告の「残り」に「手順 1: 前の段の取り込み漏れ」と書く。ブランチが引けなければ、確認を省かずに push せず、「残り」に「手順 1: 前の段のブランチが引けない」と書く
2. `git -C <wt> rev-parse --abbrev-ref @{u}` が失敗する（upstream が無い。series-init は upstream を外す。`../../series-init/SKILL.md:L97`・L101）なら、`git -C <wt> rev-parse --show-toplevel` が spec の Target の worktree と一致し、`git -C <wt> remote get-url origin` から取り出した `<owner>/<repo>`（`github.com[:/]<owner>/<repo>(.git)?` の形）が spec の Target のリポジトリと一致することを確かめてから `git -C <wt> push -u origin HEAD`。一致しなければ push せず、「残り」に「手順 2: 照合の不一致」と書く
3. upstream があれば、`git -C <wt> rev-parse --abbrev-ref @{u}` が `origin/<git -C <wt> branch --show-current の値>` であることを確かめてから `git -C <wt> push`（handoff から作った worktree は、base のブランチを追跡していることがある）。違えば push せず、「残り」に「手順 3: upstream が今のブランチを向いていない」と書く
4. 強制の push はしない（④）。必要なら完了報告の「残り」に「手順 4: 強制の push が要る」と書く

## 起動の前の確認

- **作業単位の段の数**: 1 つであること（上の前提）
- **横断計画の worktree**: 作業単位の worktree が、状態ファイルを置く横断計画の worktree と同じなら起動しない。③として「段の worktree を別に作るか」を回す（その worktree の `tmp/plan.md` は横断計画で、`/design` の上書きで消えうる。状態ファイルも同じ `tmp/` にある）。作ると答えたら、coordinator が `../../series-init/SKILL.md` の「handoff」と同じ形で、その段の引き継ぎを横断計画の worktree の `./tmp/handoff/<repo>.md` に置き（この段は handoff に回っていないので、ファイルがまだ無い）、`## 作業単位` の worktree を空にし、作業単位を `worktree 待ち` にして SKILL.md の 2 の 3 と同じく `R-<n>`（そのファイルのパスを含む）を立てる。作らないと答えたら `対象外`。series-init の確認の中でも止める（SKILL.md の 1）。これは最後の網
- **順序**: base が別の段を指す段（push の手順 1 と同じ判定）は、指す段の `## 工程の記録` に、implement の行で成否が成功のもの（完了の証拠を確かめた）があることを確かめてから起動する。まだ無ければ③にせず、起動しないで待つ（時間が経てば満たされる条件なので。ほかの確認とは扱いが違う）。それ以外の段は、series.md の `順序` に関係なく並列に起動する。状態名は工程をまたぐ順序を持たないので、状態名ではなく記録で判定する。context.md の「前提」（本番に出ていること）は、ここでは判定しない（監督の開始のときに③でまとめて確かめる。SKILL.md の 2）
  - 指す段が `対象外` になったら（理由を問わず）、指す段の `## 工程の記録` に implement の成功の行が既にあれば何もしない（順序は満たされている）。無ければ、積む段を③に回す: 「積む段も `対象外` にするか、ユーザーが手で push したことを確かめて待ちを解くか」（積む段の状態は `./state-format.md` の `<工程>: 判断待ち` の規則で決める。`未着手` なら `design: 判断待ち`、`worktree 待ち` なら書き換えない）。待ちを解くと答えたら、`git -C <指す段の wt> rev-parse @{u}` が HEAD と一致することを確かめ（`@{u}` が無い・一致しないなら、その旨を示して同じ③に戻る）、指す段の `## 工程の記録` に implement の行を成否「成功（手で push。③の答え）」で足す（以後の順序の判定はこの行で満たされる）。積む段の状態は、`design: 判断待ち` にしていたなら `未着手` に戻す（`worktree 待ち` なら書き換えていない）。作業単位を `対象外` にするたびに、その段を指す段が無いかを見る
- **review・fix・recheck**: その段の PR が open であることを `gh pr view <PR> --repo <段のリポジトリ> --json state` で確かめる。`<PR>` は series.md の段の PR 列から取り、空なら（pr の工程で登録しないで進んだなど）`gh pr list --repo <段のリポジトリ> --head <git -C <wt> branch --show-current の値> --state open --json number` で引く（recheck の `<PR 番号>` も同じ）。pr の工程の後で、ユーザーが PR をマージしたり閉じたりすることがあるため（起動したときには PR が既にマージ済みだった事故がある）。open でなければ起動せず、③としてユーザーに回す
- **同じ worktree の worker**: 状態ファイルの `## adapter` で、その worktree の試行のうち、まだ終わっていない（完了報告を受け入れていない・止めていない）ものが無いこと。あれば起動せず、ユーザーに回す。完了報告の後に残した terminal（pr の工程でユーザーが操作した terminal など）は数えない

## pr の工程

1. implement の工程の完了の証拠を確かめたら、`## 工程の記録` に pr の行を 1 行足し（試行・HEAD の欄は空、起動時刻はこの時刻。要約の欄は 4 の回数と、登録しないで進んだときの理由に使う）、作業単位を `ユーザーの操作待ち（/create-pr）` にし、adapter の「worker の terminal を残す」で implement の worker の terminal を残す
2. その terminal で `/create-pr` を打つよう、worktree と terminal を名指しして案内する。worker は完了報告を送った後なので、ユーザーが打った `/create-pr` はユーザー自身の作業になり、その中の質問（通常の PR かスタックか など）はユーザーに直接出る（worker の契約の最後の項）
3. ユーザーが作ったと伝えたとき、出来事を 1 つ処理するたび、待ち受けが時間切れになるたび、worker が 0 体でターンを終える前とユーザーの返事が来るたび（SKILL.md の 4 の「待つ相手の worker が居ないとき」）に、完了の証拠を確かめる。ユーザーの返事が無くても、証拠がそろえば進む（タイミングの正典はここ。SKILL.md はここを参照する）
4. 3 の確認で、open の PR はあるが series.md に登録が無い（register が衝突・候補なしで書かなかったなど）のが 2 回続いたら（出来事の処理・時間切れ・ターンを終える前のどの確認でも数える。続いた回数は `## 工程の記録` の pr の行の要約に「登録なし: <回数>」と書き、再開しても数を失わない）、PR と登録のどちらが欠けているかを示し、③として「`/series-sync` で登録し直すか、登録しないで進むか」を回す（登録し直すのはユーザー。`/series-sync` は register の書き手の口）。同じ作業単位にこの③は 1 回だけ立てる（`未回答` の間は、時間切れのたびに立て直さない）。作業単位の状態は `ユーザーの操作待ち（/create-pr）` のまま変えない。答えの前に登録がそろって進んだら、この③を `取り下げ` にする。登録し直すと答えたら 3 の確認に戻る。登録しないで進むと答えたら、完了の証拠から series.md への登録を外し、open の PR があることだけを確かめて 5 へ進む（理由を `## 工程の記録` の pr の行に書く。後の同期は `/series-sync` に任せる）
5. 満たしたら、作業単位を `pr: 済み` にし、adapter の「worker を解放する」で implement の worker を解放して review へ進む（ユーザーが操作した terminal は解放では閉じない。後始末は adapter）

## PR 本文の更新

coordinator が PR 本文を書くときの手順（何を書くかの仕分けは SKILL.md の 4 の完了報告の 3）。`<PR>` は「起動の前の確認」の review・fix・recheck と同じく引く。`gh pr edit` は使わない（環境によって失敗する）。

1. 書く直前に `gh pr view <PR> --repo <段のリポジトリ> --json body` で今の本文を取り直し、ファイルに残す（ユーザーや別の worktree が書き換えていることがある。古い本文に書き足すと、その変更を消す。残したファイルは消えたときの復元にも使う）
2. 書く主張を、コミットの差分（`git -C <wt> log`・`git -C <wt> diff`）で裏取りする。裏が取れない主張は書かない
3. 取り直した本文に書き足したもの（既存の行のチェックを付ける変更を含む）をファイルに置く。PATCH の直前に 1 と同じコマンドでもう一度取り直し、1 で残した本文と比べる。違えば 1 からやり直す（2 回続けば③としてユーザーに回す。2 の裏取りの間に本文が書き換わると、PATCH がその変更を消し、4 の読み直しでは気づけない）。同じなら `gh api -X PATCH repos/<owner>/<repo>/pulls/<PR> -F body=@<ファイル>` で書く
4. 1 と同じコマンドで読み直し、書いた本文と、末尾の空白・改行を除いて一致することを確かめる。一致しなければ③としてユーザーに回す

`stack-pr-submit` を再実行すると本文が丸ごと上書きされ、ここで書き足した分も消える（series-sync が入れ直すのは全体像だけ）。

## 仕分け（triage）が 0 件のとき

直すものが 0 件なら fix と recheck を飛ばす（`完了` にする前に、SKILL.md の 4 の「`完了` にする前」を当てる。下の 2 つの節と recheck の工程の `完了` も同じ）。初回の push は implement の工程で済み、PR もあり、新しいコミットも無いので push の担い手は要らない。coordinator は `git -C <wt> rev-parse HEAD` と `git -C <wt> rev-parse @{u}` の一致だけを確かめて作業単位を `完了` にし、fix と recheck の工程の記録に「飛ばした（0 件）」と書く。一致しなければ③としてユーザーに回す（coordinator は push しない）。

## fix が新しいコミットを作らなかったとき

fix の worker が全項目を対応不要と判断して、新しいコミット無しで成功を報告したら、fix の worker を adapter の「worker を解放する」で解放し（完了報告は受け入れたので）、HEAD と `@{u}` の一致だけを確かめ、③で「全項目を対応不要と判断した。完了にしてよいか」を確かめる。完了にしてよいと答えたら、fix の工程の記録に「新しいコミット無し」と書き、recheck を飛ばして `完了` にする（新しい差分が無い）。よくないと答えたら、同じ問いの選択肢として「fix を起動し直す（試行の 2 回目として数え、成功の報告の後なので「worker の起動」で新しく起動する）か、手で直す（`対象外`）か」を 1 回で決める。HEAD と `@{u}` が一致しなければ、③で一致しない旨も示す（coordinator は push しない）。

## recheck の工程

fix の後に、PR を組み込みの `code-review` で見直す。契約は 2026-10-21 にドラフトの PR を対象に `low` で 1 回実行して確かめた: ドラフトの PR を対象にできる・`--comment` を付けなければ PR にコメントもレビューも付かない・結果は文章で呼び出し元に返る（worker が転記できる）。

1. **強さ**: coordinator が起動の前に `git -C <wt> diff --shortstat <fix の工程の基準の HEAD>..HEAD` の挿入と削除の合計で決め、spec に書く（worker に規模を判断させない。判断が割れるため）。100 行未満なら `low`、100〜399 行なら `medium`、400 行以上なら `high`。しきい値は暫定（`low` は、実行できるコードの無い差分では本文を読まずに終えることがある。Markdown だけの PR で観測した）
2. **起動する skill**: Claude Code の組み込みの `code-review`（Skill ツールの名前は `code-review`。plugin の skill は `<plugin>:code-review` の名前空間付きで並ぶので、それを使わない。どちらが起動したか区別できなければ、失敗で報告する）に、強さと PR 番号を渡す。`--comment` は付けない（付けると PR に投稿する）。対象に PR 番号を渡すのは、fix のコミットが push 済みで、作業ツリーの差分が空のため。PR 全体を見る
3. **出力**: worker が `tmp/code-review.md` に、1 行目に `対象: PR #<番号>・強さ: <強さ>`、2 行目に `指摘: <件数> 件`、続けて指摘を書く（`code-review` の出力を転記する）。前の試行のファイルは上書きしてよい
4. **指摘が 1 件以上のとき**: coordinator が読んで③の表にまとめ（指摘・推奨: 直す / 直さない）、ユーザーに回す。自動で fix の 2 巡目は回さない（上限を文で決める。`../../plan-lgtm/SKILL.md:L69` と同じ理由）。答えの後:
   - 全部直さない → 理由を `## 工程の記録` に書いて `完了`
   - 1 件でも直す → `完了` にし、直す指摘を `## ユーザーへの依頼` に④（`R-<n>`。どの worktree で何を直すか）で残す
   - どちらも `対象外` は使わない（`対象外` は工程を回さない作業単位の意味。`./state-format.md` の状態名）

## 失敗したとき

- 完了報告の「残り」に push の手順で止めた旨（「手順 1」〜「手順 4」）があり、証拠の不足が push だけ（工程の基準の HEAD から新しいコミットはある）なら、起動し直さずにユーザーに回す。原因が worker の外にあり、起動し直しても同じ理由で止まるため
  - どちらも、止めた worker は adapter の「worker を解放する」で解放する（起動し直すときは新しく起動する）
  - 手順 4（強制の push）→ `R-<n>`。作業単位を `ユーザーの操作待ち（強制の push）` にする。worker は解放済みで terminal は無いので、内容にはユーザーが自分の terminal で打つものを書く（worktree のパスと `git -C <wt> push --force-with-lease`）。ユーザーが打ったと伝えたとき、時間切れのたび、worker が 0 体でターンを終える前とユーザーの返事が来るたび（SKILL.md の 4）に、`@{u}` と HEAD の一致を確かめ、一致すれば `## 工程の記録` のその試行の行の成否を「成功（強制の push はユーザー）」で埋め（順序の判定はこの行を見る）、`R-<n>` を `済み`、作業単位を `<工程>: 済み` にする
  - 手順 1（前の段の取り込み）・手順 2（照合の不一致）・手順 3（upstream の向き）→ `Q-<n>`。作業単位を `<工程>: 判断待ち` にする。手順 1 で「取り込む」と答えたら、同じ工程を「worker の起動」で起動し直す（spec の Change に「前の段のブランチを取り込んでから push の手順を行う」と書く）。「取り込まない」なら、手順 1 を省いてよいかを同じ答えで決め、省くなら spec にそう書いて同じ形で起動し直す。手順 2・3 は、問いに不一致の中身（toplevel と Target・origin とリポジトリ・upstream の向き）を示し、ユーザーが直した（または spec の Target を直すと答えた）後に、同じ形で起動し直す。どちらも試行の回数に数えない（`## 工程の記録` には新しい行を足し、試行の欄に前と同じ番号と「（取り込みの後）」を書く。工程の基準の HEAD は書き換えない）
- それ以外で、完了報告が失敗、または成功の報告でも完了の証拠を満たさないときは、同じ工程を 1 回だけ起動し直す。2 回目も失敗ならユーザーに回す（③として扱う）
  - 失敗の報告・止めた試行の後は、adapter の「工程の再試行」で起動し直す
  - 成功の報告で証拠を満たさないときは、その試行は成功として終わっていて再試行の対象にならないので、adapter の「worker を解放する」の後、「worker の起動」で新しく起動する（試行の回数は 2 回目として数える）
- 失敗を受け入れた worker の terminal は、起動し直す前に adapter の「worker を解放する」で片付ける（ユーザーが中を見たいと言ったときだけ「worker の terminal を残す」）。2 回目の失敗でユーザーに回すときも同じ
- 自動で 3 回以上は回さない。series-run はコードを持たず、上限の遵守はモデルの instruction-following に依存するので、上限を文で決めておく（`../../plan-lgtm/SKILL.md:L69` と同じ理由）
- 試行の数え方:
  - **起動そのものの失敗**（起動の応答が失敗・結果が不明）は、worker の失敗報告と分ける。試行の回数に数えず、adapter の「起動の失敗の扱い」に回す
  - **死んだ worker**（終了の積極的な証拠がある）は、adapter の「試行を止める」で止めてから扱う。トランスクリプトがあれば（作業を始めていた）、完了報告が失敗だったときと同じく試行の 1 回に数える（数えないと、毎回途中で死ぬ worker が上限なしに起動し直される）。トランスクリプトが無ければ（作業を始める前に死んだ）試行に数えずに 1 回だけ起動し直し、2 回続いたらユーザーに回す（続いた回数は `## 工程の記録` の成否の欄に「起動直後に死亡」と書いて数える。再開しても数が失われない）（ツールが起動の成功を返した後の死なので、ツール側の起動の失敗の上限には数えられない）

## fix の 2 巡目

SKILL.md の 4 の「`完了` にする前」で、後の段から届いた指摘を直すと答えたときだけ、fix に入る（この確認から fix に入るのは作業単位ごとに 1 回だけ）。triage が 0 件で fix を飛ばしていたなら、これは fix の 1 巡目として扱い、巡を添えずに通常の fix の工程として回す。fix を既に回していたなら 2 巡目で、次のとおり扱う。

- 工程の基準の HEAD は、2 巡目の 1 回目の試行の起動時に取り直す（1 巡目のコミットを 2 巡目の成果と数えない。recheck の強さも 2 巡目の差分で決まる）
- 試行の回数も 2 巡目で 1 から数え直す（上限の 2 回は巡ごと）。`## 工程の記録` の試行の欄には `2-1`・`2-2` のように巡を添える
- 2 巡目の fix の後も recheck を回す（`完了` の前の確認も同じく当てる）。2 巡目の後に入り直す答えが出ても、3 巡目は回さない（SKILL.md の 4）

## 工程の境目での `tmp/` の退避（B6 の差し込み口）

同じ worktree で工程が進むと、後の工程の skill が前の工程の `tmp/` の成果物を上書きする（例: fix-lgtm-implement の中の review-plan が `tmp/plan-review.md` を作り直す）。工程の境目での `tmp/` の退避の規則は、`feat-tmp-okf-document` の決定に従う（未決）。

決まるまでは、design の工程の完了の証拠を確かめたときに、`tmp/plan-review.md` の `**総合判定**`・`**対象**`・更新時刻の 3 点を状態ファイルの `## 工程の記録` の要約の欄に写す（後の工程が同じファイルを上書きしても、判定の記録が残る。写す規則の正典はここ）。ファイルそのものは動かさない（退避の規則を先取りしないため）。triage が `tmp/fixes.md` を書く前に既存のものを `tmp/fixes.archived-<日時>.md` に移すのも、この決定が出るまでの暫定である。
