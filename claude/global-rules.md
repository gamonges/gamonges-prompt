## Skills 共通規約

本ブロックは `gamonges-prompt` の `./setup.sh install` が配置する。直接編集せず、リポジトリ側の `claude/global-rules.md` を変更して install し直す。

- レビュー指摘・コード参照は `file_path:L{number}` 形式で書く
- ソースコードを変更しない skill は、出力先を skill 本文に明記する（例: `./tmp/research.md`）
- 成果物を人が読む形にする場合、完了報告に続けて Artifact 化を提案する（提案は完了報告時に 1 回だけ）。例外は `grill` — Phase 0 完了時に 1 回提案し、以後は決定が入るたびに同一 URL へ再 publish する

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

**OpenSpec 拡張**: `openspec/config.yaml` があるプロジェクトでは `/design → /spec-check → … → /implement → /spec-propose → /spec-archive` で仕様を永続化する。無ければ標準フローのみ。

本節も `claude/global-rules.md` で管理する。直接編集せず、リポジトリ側を変更して install し直す。
