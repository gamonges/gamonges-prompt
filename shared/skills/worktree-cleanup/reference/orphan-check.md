# 孤児 collection の点検（worktree-cleanup Step 6 補助）

## 孤児の定義

**元パスがディスクに存在しない claude-context collection** を孤児とする。元パスは collection の description（`codebasePath:<絶対パス>`）から取り、description に無ければ snapshot（`~/.context/mcp-codebase-snapshot.json`）のキーのうち、`md5(path.resolve(key))` の先頭 8 桁が collection 名の末尾と一致するものを使う。

「snapshot に無い collection」を孤児とはしない。claude-context（upstream）の挙動により snapshot の中身が揺れるため:

- MCP の起動時に、パスが存在しない snapshot エントリは **snapshot からだけ**除去され、collection は残る（孤児の発生源）
- `index_codebase` / `search_code` / `get_indexing_status` の冒頭の同期が、snapshot に無い collection を description から snapshot へ**書き戻す**（パスの実在は見ない）。次回起動時にまた除去される

snapshot は同期のたびに孤児を含んだり含まなかったりするので、差分では判定が安定しない。snapshot が消えていた場合に全件を孤児と誤判定する危険もある。

## 手順

1. list モードで実行する（SKILL.md の Step 6 のコマンド）
2. 結果を提示する。孤児は表で、unknown は別枠で示す:

   ```
   孤児点検（点検先: http://localhost:19530 / 設定の解決元: claude.json）

   【孤児 collection】元パスが存在しない
     | # | collection | 元パス | 行数 |
     |---|-----------|--------|------|
     | 1 | hybrid_code_chunks_xxxxxxxx | /path/to/deleted-worktree | 12,345 |

   【出所不明のため対象外】
     - code_chunks_yyyyyyyy — description に codebasePath が無く、snapshot にも一致するパスが無い

   drop しますか？（全件 / 番号指定 / いいえ）
   ```

3. 承認を取る。**Step 4 の承認とは別に取る**（worktree と無関係な collection を消すため）。unknown は承認の対象にしない
4. 承認された名前だけを渡して drop モードで実行する:

   ```bash
   node ~/.claude/skills/worktree-cleanup/scripts/find-orphan-collections.mjs --drop <name> [<name>…]
   ```

   script は各名前をその場で判定し直し、孤児のときだけ drop する（提示から承認までの間に、同じパスでディレクトリが作り直される場合に備える）
5. 結果を `results[].status` ごとに報告する: `dropped`（削除した）/ `refused`（再判定で孤児ではなくなっていたので送らなかった。`detail` に理由）/ `error`（drop 要求が失敗した。警告として示す）

孤児が 0 件なら「孤児 collection なし（<milvus> の N 件を点検）」と 1 行で報告して終える（N は `liveCount` + `unknown` の件数 + 孤児の件数）。unknown があれば、0 件の報告に続けて別枠で示す。

## unknown が出る主な理由

- description が無い旧形式の collection で、snapshot からも元パスが消えている。MCP 自身の同期は document の metadata を query するフォールバックを持つが、script は持たない（判定材料を増やすより、特定できないものを drop しない側に倒すため）
- describe の失敗（`code≠0`）
- 元パスの md5 が collection 名のハッシュと一致しない（description の改ざん、または命名規則の変更）
- 元パスはあるがディレクトリではない / 権限等で実在を確認できない

## 接続設定の解決順

変数（`MILVUS_ADDRESS` / `MILVUS_TOKEN`）ごとに、空文字は未設定として次へ進む:

1. `~/.claude.json` の `mcpServers.claude-context.env`
2. シェルの環境変数
3. `~/.context/.env`（`NAME=value` 行）
4. 既定値（`MILVUS_ADDRESS` のみ `localhost:19530`）

MCP と同じ Milvus を点検するため、この順にしている。MCP の接続設定は `~/.claude.json` にあり、シェルには無い。シェルを先に見ると、MCP とは別の Milvus を点検して「孤児 0 件」と報告しうる。プロジェクトスコープの MCP 設定（`projects.<path>.mcpServers`）は読まない（読むと cwd によって点検先が変わる）。どこから解決したかは stdout の `milvusSource`（`claude.json` / `env` / `dotenv` / `default`）に出る。

## 注意

- **drop 後に snapshot を手で編集しない**。次の同期で「Milvus に無いローカルエントリ」として除去され、自己修復する
- **複数の端末・複数人で共有する Milvus では、他の端末のパスが孤児に見える**。判定は「この端末のディスクに元パスがあるか」だけで、どの端末が作った collection かは見ないため。点検先（`milvus`）が `localhost` 以外なら、表の元パスがこの端末のものか確かめてから番号指定で承認し、全件承認は使わない
- **外付けボリューム上のパスは、アンマウント中だと「存在しない」と判定される**。表の元パスを見て、該当するものは番号指定で外す
- **行数は `get_stats` の flush 済み行数**で、書き込み直後の collection では 0 になりうる（表示用で、分類には使わない）。`count(*)` クエリは collection の load を要するため使っていない
- `MILVUS_TOKEN` は `Authorization: Bearer` として送るが、認証付きの Milvus（Zilliz Cloud 等）では未検証

## 依存する内部仕様と確認した版

script は claude-context の次の内部仕様に依存している:

- collection 名: `(hybrid_)?code_chunks_` で始まり、`_<md5(path.resolve(codebasePath)) の先頭 8 桁>` で終わる（名前の override を設定しても末尾のハッシュは維持される）
- collection の description: `codebasePath:<絶対パス>`
- snapshot: v2 形式（`formatVersion: "v2"`、`codebases` のキーが絶対パス）
- Milvus REST v2: `/v2/vectordb/collections/{list,describe,get_stats,drop}`。エラーも HTTP 200 で返し、body の `code` で成否を示す

確認した版は claude-context-mcp 0.1.13–0.1.15。版上げでこれらが変わっても、script は判定できないものを unknown に倒すため誤 drop にはならない。変化は「unknown が急増する」形で表に現れる。
