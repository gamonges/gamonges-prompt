---
name: stack-pr-submit
description: スタックの各レイヤーを PR 化し create-pr と同じ本文テンプレートを適用する。「スタックを PR 化」「まとめて submit」`/stack-pr-submit` で使用
---

現在のスタックの各レイヤーを GitHub 上の PR として一括作成・更新する。`gh stack submit` にはタイトル・本文をコマンドから直接渡すオプションが無い（対話ターミナルでは単一画面エディタ、非対話では auto-generated タイトルのみ）ため、`--auto` で PR を作成した後に `gh pr edit` で本文を上書きする 2 段階方式を取る。

## 前提条件チェック

詳細は `../stack-pr-init/SKILL.md` の「前提条件チェック（SSOT）」を参照し同じチェックを行う（再宣言しない）。

## 実行プロセス

### 1. スタック構成の取得

`gh stack view --json` で現在のブランチ一覧・親子関係・既存 PR の有無を取得する。

### 2. 各レイヤーの変更分析

各ブランチについて `create-pr` の Phase 3-4 相当のロジックを、そのブランチの**直接の親ブランチ**（trunk またはスタック内の 1 つ下のブランチ）を基準に実施する:

- `git diff <parent>...<branch>` で変更ファイル・diff stats を取得
- `git log <parent>..<branch>` でコミットメッセージを収集
- 変更内容とコミットメッセージから PR の目的（機能追加 / 仕様変更 / バグ修正 / リファクタリング）を判定する

### 3. PR タイトル・本文の生成

- タイトル: `create-pr` Phase 2 のブランチ命名規則ロジックを各ブランチ名に適用する
- 本文: `../create-pr/reference/pr-description-template.md` の構成に従う
- Notion Page ID の抽出・`ref` 行付与ルールは `../create-pr/SKILL.md` の「Notion Page ID によるリファレンス付与」を SSOT として踏襲する（再宣言しない）。ID が指定された場合、スタック全体が単一の要求に対応する変更であるとみなし、**生成する全レイヤーの PR 本文に同じ `ref` 行を付与する**（レイヤーごとに異なる Notion ページへの分割は本 skill の対象外）

### 4. PR の作成

```bash
gh stack submit --auto
```

新規 PR は draft として作成される（`--open` は付与しない。draft 解除は `create-pr` 同様ユーザー操作に委ねる）。

### 5. 本文・タイトルの上書き

```bash
gh stack view --json
```

で作成された PR 番号とブランチの対応を取得し、各 PR に対して:

```bash
gh pr edit <number> --title "<generated-title>" --body "<generated-body>"
```

を実行し、ステップ 3 で生成したタイトル・本文に上書きする。PR 番号が取得できなかったブランチは本ステップの対象から除外し、ステップ 6 の失敗一覧に含める。`gh pr edit` が個別に失敗した場合も処理を中断せず次のレイヤーに進む。

### 6. 完了報告

各レイヤーの PR 番号・URL・タイトルの一覧、および `create-pr` と同様に「関連リンクの追加」「動作確認チェックリストの確認」「draft 解除」「レビュアーのアサイン」を次のアクションとして案内する。一部レイヤーの PR 作成に失敗した場合は、成功/失敗レイヤーを分けて報告する。`gh stack submit` は PR が無いブランチのみ新規作成し既存 PR は base branch 更新のみ行う（重複作成しない）ため、本 skill を再実行すれば失敗分のみ再試行できる旨を案内する（`gh stack submit --help` の記述に基づく想定。実機未検証のため、初回実行時は結果を注意深く確認する）。
