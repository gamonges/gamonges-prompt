## Skills 共通規約

本ブロックは `gamonges-prompt` の `./setup.sh install` が配置する。直接編集せず、リポジトリ側の `claude/global-rules.md` を変更して install し直す。

- レビュー指摘・コード参照は `file_path:L{number}` 形式で書く
- ソースコードを変更しない skill は、出力先を skill 本文に明記する（例: `./tmp/research.md`）
- 成果物を人が読む形にする場合、完了報告に続けて Artifact 化を提案する（提案は完了報告時に 1 回だけ）。例外は `grill` — Phase 0 完了時に 1 回提案し、以後は決定が入るたびに同一 URL へ再 publish する
