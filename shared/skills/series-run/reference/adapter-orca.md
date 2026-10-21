# adapter: Orca

series-run の SKILL.md が使う操作名を、Orca のコマンドに当てはめる表と、Orca 固有の運用知見。Orca のコマンドは series-run の中でこのファイルにだけ書く（ほかのファイルは操作名で書く）。ツールを替えるときは、このファイルと状態ファイルの `## adapter` 節だけを差し替える。

**このファイルは Orca の kernel の上に乗る。** kernel は `orca skills get orchestration` で、使っている Orca の版に合ったものがバイナリから取れる。対応表と運用知見だけをここに置き、手順の正は kernel に置く。このファイルと kernel が食い違えば kernel に従う（このファイルの記述が古くなっても、正しい手順は kernel 側に残る）。

## 応答の形

Orca の `--json` の応答は `{"ok": …, "result": {…}}` で包まれる。パスやキーを誤って読むと、Orca が不調に見えたり、一覧が空に見えたりする。

- 状態: `.result.runtime.state`（`.result` を落とすと読めない）
- worker の一覧: `.result.workers[]`
- 一覧が空のときは、`.result.scope.run` が意図した Run か確かめる。存在しない Run を渡してもエラーにならず、`ok: true` で空の一覧が返る
- 結果が空・不審なときは、Orca の不調と決める前に、まず自分の読み方（パス・キー・Run の指定・タイミング）を疑う

## 前提の確認と kernel

1. `orca status --json` の `.result.runtime.state` が `ready`。そうでなければ、他のツールに切り替えずに止まって報告する
2. `.result.runtime.runtimeId` を状態ファイルの `## adapter` に控える。再開のときと、`runtime_unavailable` から戻ったときに比べ、変わっていれば Orca が再起動したとみなして、その時刻を「最後の再起動の時刻」に書く（coordinator のセッションが閉じている間の再起動に気付くため。再起動のたびに値が変わるかは未確認）
3. `orca skills get orchestration` で kernel を読む。kernel の「Conditional references」の表で条件に当たった reference だけを、`--reference references/<file>.md` で読む

## 操作の対応表

`<run_id>` などの ID は、状態ファイルの `## adapter` 節から取る。coordinator が自分の Orca の terminal で動いているときは、`check` に `--terminal` を付けない。Orca の terminal の外で動いているときは、`check` に `--terminal <自分の handle>` を付ける（kernel の「Canonical supervised loop」）。

| 操作 | Orca |
|------|------|
| 監督の開始 | `orca orchestration run-create --objective "<series の title>" --json` |
| 既存の監督につなぐ（再開） | `orca orchestration run-use --id <run_id> --json` |
| worker の起動 | `orca orchestration worker-start --spec "<spec>" --worktree path:<worktree> --agent <claude\|codex> --run <run_id> --json`。応答の Task ID・Dispatch ID・terminal の handle を `## adapter` に書く。既存の worktree では setup を再実行しない |
| 工程の再試行 | `orca orchestration worker-start --task <失敗した Task ID> --retry-of <dispatch_id> --worktree path:<worktree> --agent <claude\|codex> --run <run_id> --json`。失敗の報告（`failed`）か止めた（`stopped`）試行にだけ使う（`references/recovery-and-cleanup.md` の「Retry, stop, and abandon」）。`--retry-of` は `--task` が要り、配置を引き継がないので、worktree と agent を改めて指定する（`worker-start --help` の Notes） |
| 試行を止める | 終了の積極的な証拠があるときだけ、`worker-list --run <run_id> --json` のその行の `projection.nextAction` が `worker-stop` か `worker-abandon` を指せばそれに従い、argv が無ければ `orca orchestration worker-stop --dispatch <dispatch_id> --json`。`nextAction` がほかの操作を指すとき、`worker-stop` が失敗したとき、`worker-abandon` を使ったとき（試行が stopped にならず、`--retry-of` の対象外になる）は、工程の再試行に進まず③としてユーザーに回す。どれも終了の証拠の無い試行には使わない |
| 出来事を待つ | `orca orchestration check --wait --run <run_id> --types "worker_done,escalation,question" --timeout-ms 900000 --json` |
| 出来事を処理済みにする（と次を待つ） | `orca orchestration check --ack <delivery_id> --wait --run <run_id> --types "worker_done,escalation,question" --timeout-ms 900000 --json`。ack はバッチ全体に効く |
| 質問に答える | `orca orchestration reply --id <message_id> --body "<答え>" --run <run_id> --json` |
| 追加の指示を送る | `orca orchestration send --to dispatch:<dispatch_id> --run <run_id> --subject "<要旨>" --body "<指示>" --json`。成功は受信箱に入ったことしか示さない。worker は区切りのたびにしか読まない（kernel の「Worker obligations」3） |
| worker の terminal を残す（ユーザーの操作待ち） | `orca orchestration worker-retain --dispatch <dispatch_id> --json` |
| worker を解放する | `orca orchestration worker-release --dispatch <dispatch_id> --json` |
| 生存の確認 | `orca orchestration worker-list --run <run_id> --json` の各行の `projection.liveness`（`live`・`unverifiable`・`exited`。kernel の「Authority and safety floor」）を入口にする。行の中の正確なパスは未確認なので、初回に 1 行を見て確かめる。進んでいるかは `orca orchestration worker-read --dispatch <dispatch_id> --source transcript --json` の最終時刻、入力待ちのプロンプトと権限確認の画面は `--source terminal` で見る（下の「生存の判定」） |
| 残った terminal を閉じる | `orca terminal close --terminal <handle> --json`。下の「完了の後始末」の確かめの後で、`retained` の terminal にだけ使う |
| worker 側の手段 | 注入された preamble にある `ask`・`send --type heartbeat`・`check --terminal`・`send --type worker_done --outcome succeeded\|failed` をそのまま使う。spec には書かない（preamble の引数を組み立て直さない。kernel の「Authority and safety floor」） |

## 状態ファイルの `## adapter` 節に書くもの

- Run ID
- 作業単位ごとの Task ID・Dispatch ID・terminal の handle（再試行のたびに新しい Dispatch ID を足し、古いものは消さない）
- ③の問いの番号 → message ID の対応（「質問に答える」の `--id` に使う。再開した後も答えを元の worker に返せるようにする）
- worker ごとの最後の heartbeat の送信時刻
- `runtimeId` と、最後の Orca の再起動の時刻（`ready` に戻った時刻。heartbeat の割り引きに使う）

## 待ち受けの戻り

- `check` が返す Delivery は FIFO のバッチ全体で、`--types` では絞られない（`--types` は `--wait` が起きる条件にすぎない。`check --help`）。heartbeat が混ざることも、heartbeat だけのこともある
- ack するまで同じバッチが返り続ける。バッチの全メッセージを処理してから ack する（途中で ack すると残りを失う）
- 待ち受けは Run に 1 つだけ張る（2 つ目は `waiter_exists` になる）
- 待ち受けの出力を捨てない・jq で絞らない（`worker_done` を取りこぼす）。出力をファイルに受けたときは、JSON が複数並ぶことがある
- heartbeat も ack する
- 空の待ち受けが 3 回続いたら、`worker-list --run <run_id> --include-remote --json` で各行の `projection.attention` と `projection.nextAction` を見て、kernel の「Canonical supervised loop」に従う（`nextAction` が `none` なら argv は無い）

## 生存の判定

kernel は「Heartbeat or visible activity means alive, not done.」（`references/messaging-and-gates.md` の「Coordinator delivery loop」）とし、終了の積極的な証拠が無い限り、止まったとみなさない（kernel の「Outcome」の Safe failure）。ここではこの規則に従い、信号として数える範囲を、古さで割り引くだけにする。kernel は信号の古さの基準を定めていないので、足しても規則は弱めない。

**生存の信号は 2 つ:**

- **heartbeat**: ただし、送信の時刻が `## adapter` の最後の再起動の時刻より前のもの（再起動の後に届く滞留分。worker は既に死んでいることがある）と、待ち受けの時間（15 分）より古いものは数えない
- **トランスクリプトの最終時刻**（`worker-read --source transcript`）

terminal の末尾（`--source terminal`）は信号に数えない。再描画の残骸で「作業中」に見えることがある。terminal は、入力待ちのプロンプトと権限確認の画面の有無を見るためだけに使う。

**判定する時:** 待ち受けが出来事なしで時間切れになるたび、生存の確認で `unverifiable`（`stale_status`・`restored_unconfirmed` など）が出たとき、Orca の再起動の後（kernel の「An empty wait or timeout is a checkpoint」と同じ位置づけ）。

**対象:** 生きているはずの worker。次の 2 つは除く。

- 作業単位が `ユーザーの操作待ち` の worker（pr の工程で残した terminal など）
- `## ユーザーへの依頼` に未回答の③の問いがある worker。`ask` で待つ worker は heartbeat を送らない（`references/worker-contract.md`）。kernel では、`ask` で待っていること自体が生存の信号である

**判定の表**（上の行から順に当て、最初に当たった行で決める。権限確認の画面は、直前の heartbeat で信号が動いていても見逃さないよう、先頭に置く）:

| 順 | 状態 | 扱い |
|----|------|------|
| 1 | 権限確認の画面で止まっている | ③としてユーザーに回し、どの terminal で何を承認するかを案内する（権限確認で何時間も止まったまま、誰も気付かなかった事故がある） |
| 2 | 待ち受けの時間内に、トランスクリプトか、割り引いた後の heartbeat が動いた | 生きている。待つ |
| 3 | 空の入力待ちのプロンプトで、完了報告が無く、信号も動いていない | 「追加の指示を送る」で状況の報告を求める。次の時間切れまで応答が無ければ③（報告を出さずに作業を終えていた事故がある） |
| 4 | 終了の積極的な証拠がある（`exited` の liveness、プロセスの終了など。`references/recovery-and-cleanup.md` の「Stall needs positive evidence」。`unverifiable` と、変わらない terminal の末尾は証拠にならない） | 「試行を止める」の後、段の型の「失敗したとき」の「死んだ worker」へ（トランスクリプトの有無で試行に数えるかが決まる） |
| 5 | どれにも当たらない（信号は動いていないが、プロンプトも画面も見えない） | 終了の積極的な証拠が無いので、止まったとみなさない。次の時間切れでもう一度判定し、2 回続いたら③ |

「進んでいない」のしきい値は、待ち受けの時間の間にトランスクリプトの最終時刻も heartbeat も動かなかったこと。`--source transcript` は hook の報告に依存するので、取れない worker では heartbeat だけで判定する。

## 起動の失敗の扱い

`worker-start` が非 0 で終わった、または結果が不明な応答のときは、起動し直さない。応答の `failedStage` と `residualResources` を読み、kernel の `references/recovery-and-cleanup.md` に従う（kernel の「Canonical supervised loop」）。worker の失敗報告とは分け、段の型の試行の回数に数えない。

起動の失敗の上限は Orca 側にある。1 つの Task で起動の失敗が 3 回続くと、その Task は失敗になり、`--retry-of` は `task_not_startable` で拒まれる。拒まれたら③としてユーザーに回す。新しい Run や Task で回り込まない（同 reference の「Retry, stop, and abandon」）。

## 運用知見

- Orca の再起動で `runtime_unavailable` になったら、`ready` に戻るのを待ってやり直す。戻ったら最後の再起動の時刻を書き、全 worker の生存を判定し直す
- release の応答が `retained`（`user_takeover`）になるのは、ユーザーがその terminal を操作したとき（権限確認への応答を含む）。解放では閉じない
- 解放の応答が `release_pending`・`release_unknown` なら、応答にある復旧の手順に従う。`terminal close` で代わりに閉じない（`references/recovery-and-cleanup.md` の「Retain and release」）
- タイムアウト・アイドル・heartbeat・質問・escalation を理由に解放しない。解放してよいのは、受け入れた完了報告の後だけ（同上）
- 既知の現象: worker の起動のたびに、メインのチェックアウトの古い `.claude/` が書き込まれ、マージを邪魔することがある（原因は未特定）。worker がこれで詰まったら、patch で退避するよう返す

## 完了の後始末

1. 作業単位の完了報告を受け入れたら、kernel の「Completion accounting」に従い、ユーザーの操作待ちの作業単位は「worker の terminal を残す」、それ以外は「worker を解放する」
2. `worker-list --run <run_id> --terminal-state reclaimable --json` が空になるまで、監督を終えない
3. pr の工程では、ユーザーが implement の worker の terminal で `/create-pr` を打つので、その terminal は `user_takeover` になり、解放では閉じない。監督の終わりに `worker-list --run <run_id> --terminal-state retained --json` を一覧し、閉じる前に 3 点を確かめる
   1. handle が `## adapter` 節の記録と一致する
   2. terminal の題名が作業単位と一致する
   3. 長く動くプロセス（開発サーバーなど）を持っていない。`worker-read --dispatch <dispatch_id> --source terminal --json` の画面が、シェルのプロンプト（またはエージェントの入力待ち）に戻っていて、前面で動くプロセスの出力が流れていないことで見る
4. 3 点を確かめられたものだけを「残った terminal を閉じる」で閉じる。それ以外は閉じずに報告に残す

## 再開

1. 前提の確認（`runtimeId` の比較を含む）と kernel の読み込み
2. `run-use --id <## adapter の Run ID>` で、既存の Run にこの coordinator をつなぐ。`check` は `--run` を省くと呼び出し元に紐づいた Run を読むため（`run-use --help`）。つながったことを応答で確かめる
3. `check --run <run_id> --json`（`--wait` を付けない）と `worker-list --run <run_id> --json` で、未処理の出来事と生きている worker を、状態ファイルの作業単位の行に突き合わせる
4. 以後の待ち受け・ack・一覧・返答・送信にも `--run <run_id>` を付ける
