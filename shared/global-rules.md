## Skills 共通規約

本ブロックは `gamonges-prompt` の `./setup.sh install` が配置する。直接編集せず、リポジトリ側の `shared/global-rules.md` を変更して install し直す。

- レビュー指摘・コード参照は `file_path:L{number}` 形式で書く
- ソースコードを変更しない skill は、出力先を skill 本文に明記する（例: `./tmp/research.md`）
- `tmp/` の md には frontmatter が要る。書式は `python3 ~/.claude/scripts/knowledge.py spec`
- 成果物を人が読む形にする場合、完了報告に続けて HTML 化を提案する（`html-view` で `tmp/<basename>.html` を生成してブラウザで開く。提案は完了報告時に 1 回だけ）。Artifact（共有ページ）はユーザーが共有を求めたときだけ使う。例外は `grill` — Phase 0 完了時に 1 回提案し、以後は決定が入るたびに `tmp/grill.html` を更新する
- `tmp/` の成果物は、skill の開始時点で既に存在し、かつ skill 本文にその扱い（追記・resume・作り直し・上書き/追記/キャンセルの確認）が書かれていなければ、書き出す前に上書き / 追記 / キャンセルを確認する。誰が作ったかは判断せず、開始時に存在するかだけで決める（別のセッションの成果物を黙って上書きしないため）。上書きが契約の skill（`revise`・`review-plan`・`review`）は対象外

## 説明の書き方（オーナーがすぐ認知できるように）

オーナーは間を空けて読むので、前に定義した記号や前の報告の文脈を覚えていない前提で書く。

- 報告・説明の冒頭 2〜3 行に「要するに」の 1 文と、オーナーが決めること（無ければ「決めることなし」）を置く
- 記号・略語・自分で付けたラベル（区分 C・Q-3・K-21 など）は、出すたびに 10 字程度の意味を添える。前に説明したかで省かない
- 判断待ちは 1 件ずつ自己完結させる（何の話か・選択肢・推奨を先頭に・選ぶと何が起きるか）。番号だけにしない
- 1 つの報告で記号の体系を混ぜない。記号が多いときは冒頭に凡例を置く。状態遷移・経路は最初から図か表にする
- 区切りの報告の最後に「現在地」（動いている作業・待っている判断・次にやること）を置く。オーナーが迷ったら `/where` で同じ形にまとめ直す

## コマンドの実行

- シェルは zsh のことがある。複数の語を 1 つの変数に詰めて未クオートで展開しない（zsh では分割されず 1 語で渡る）。配列か環境変数（`AWS_PROFILE` など）で渡す

## 開発サイクル（スラッシュコマンド）

標準フロー:

```
/ask → /grill → /design → /review-plan ⇄ /revise → /implement → /review → /fix → /implement fix-plan → /create-pr
```

| コマンド | 役割 | 出力 |
|----------|------|------|
| `/brief` | 用途別テンプレートで質問ファイルを作る（任意の前工程） | `tmp/context.md` |
| `/ask` | 調査・質問回答 | `tmp/research.md` |
| `/grill` | 前提と業務シナリオの壁打ち | `tmp/grill.md`・`tmp/scenario.md` |
| `/design` | 実装計画の作成 | `tmp/plan.md` |
| `/review-plan` | 計画のレビュー | `tmp/plan-review.md` |
| `/revise` | 計画の修正 | `tmp/plan.md` |
| `/implement` | TDD 実装 | ソースコード |
| `/review` | 並列レビュー | `tmp/review/unified.md` |
| `/fix` | 修正計画の作成 | `tmp/fix-plan.md` |
| `/create-pr` | PR 作成 | GitHub PR |
| `/status` | 進捗・ワークフロー状態の表示 | コンソール |
| `/where` | セッションの要約・現在地・記号の凡例・決めること | コンソール |

**OpenSpec 拡張**: `openspec/config.yaml` があるプロジェクトでは `/design → /spec-check → … → /implement → /spec-propose → /spec-archive` で仕様を永続化する。無ければ標準フローのみ。

本節も `shared/global-rules.md` で管理する。直接編集せず、リポジトリ側を変更して install し直す。
