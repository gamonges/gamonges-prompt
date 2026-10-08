# SKILL.md frontmatter スキーマと H5 lint 検査仕様

> H5 hook (`hook-lint-skill-frontmatter.sh`) が参照する正準仕様。
> SKILL.md 編集前 (PreToolUse) に必須フィールドの欠落とトリガー語不足を検査する。

## frontmatter 全フィールド（公式: https://code.claude.com/docs/en/skills）

### 必須（H5 lint で deny 判定）

| フィールド | 説明 |
|-----------|------|
| `name` | skill 識別子。ディレクトリ名と一致させる。半角小英数字とハイフンのみ、64 文字以下 |
| `description` | この skill が何をするか / いつ使うか。Claude が自動選択する際の判定に使う |

### オプション（H5 lint では存在チェックのみ。値の検証は実施しない）

| フィールド | 説明 |
|-----------|------|
| `when_to_use` | description に追加するトリガー文脈 |
| `argument-hint` | autocomplete で表示する引数ヒント（例: `[issue-number]`）|
| `arguments` | 名前付き位置引数の定義（`$name` 置換に使う）|
| `disable-model-invocation` | Claude 側の起動を**全経路**ブロック（下記「起動制御フィールド」参照）|
| `user-invocable` | `false` で `/` メニュー非表示（Claude は呼出可能。listing budget は減らない）|
| `allowed-tools` | skill 有効時に承認なしで使える tool 一覧 |
| `model` | skill 専用モデル（session モデルを override）|
| `effort` | skill 専用 effort level（session effort を override）|
| `context` | `fork` で subagent context 実行 |
| `agent` | `context: fork` 時に使う subagent type |
| `hooks` | skill ライフサイクル限定の hooks |
| `paths` | この skill を自動 load するファイルの glob パターン |
| `shell` | `bash`（default）または `powershell` |

### 起動制御フィールド（`disable-model-invocation` / `user-invocable` / `skillOverrides`）

3 者の違い・listing budget への効き方・**付けてはいけない skill**（`Skill` ツール連鎖 / subagent preload の被呼び出し側）は `shared/skills/skill-authoring/SKILL.md` の「起動制御フィールドの選び方」を参照（本ファイルでは再宣言しない）。

要点だけ: `disable-model-invocation: true` は「Claude 自動呼出の禁止」に留まらず、**`Skill` ツールからのプログラム的呼び出し・subagent への preload・scheduled task 起動もすべてブロック**する。被呼び出し側の skill に付けるとワークフロー連鎖が実行時に壊れる。

**Codex 側の対応**: `disable-model-invocation` は Codex に効かない。Codex で自然文からの暗黙起動を止めるには、skill ディレクトリに `agents/openai.yaml` を置き、`policy:` の下に `allow_implicit_invocation: false` を書く（内容は全 skill 共通の 2 行）。明示呼び出し（Codex では `$<skill-name>`）は引き続き使える。`verify-skills.sh` の check 9 が、`disable-model-invocation: true` の skill の集合とこのファイルを持つ skill の集合の一致を検査する。`user-invocable: false` の skill には置かない（Codex に同じ意味のフィールドが無く、`/` メニューから隠せないことを許容している）。

## H5 lint の検査ロジック

### 1. 検査対象判定

ファイルパスから検査要否を決める:

```bash
# ファイルパスが */SKILL.md でなければ exit 0 (素通し)
if [[ ! "$FILE_PATH" =~ /SKILL\.md$ ]]; then exit 0; fi

# _ プレフィックスディレクトリ (_template, _example 等) は除外
if [[ "$FILE_PATH" =~ /_[^/]+/SKILL\.md$ ]]; then exit 0; fi
```

`setup.sh:install_skills()` の `[[ "$skill_name" == _* ]] && continue` と判定基準を統一する。

### 2. 検査対象テキストの構築

入力 JSON の `tool_name` で分岐:

- **Write**: `tool_input.content` をそのまま検査
- **Edit**: 既存ファイルを読み、`tool_input.old_string` を `tool_input.new_string` で 1 回置換した結果を検査
- **MultiEdit**: 既存ファイルを読み、`tool_input.edits[]` を順次 1 回ずつ置換した結果を検査（W-B 対応で Python フォールバック推奨）
- **apply_patch**（Codex）: 入力に `tool_input.file_path` が無く、patch 本文は `tool_input.command` にある。上の「1. 検査対象判定」より前に分岐し、patch が触れる `SKILL.md`（`Move to` の移動先を含む。Delete は対象外）ごとに、現ファイルへ patch を当てた後の本文（Add File は追加行）を、Write / Edit / MultiEdit と同じ検査にかける。patch を解釈できないときは `SKILL.md` に触れる疑いがあれば止め、現ファイルに当てられないときはその `SKILL.md` で止める（fail-closed）

### 3. frontmatter 抽出

`---` で囲まれた YAML ブロックを抽出:

```bash
extract_frontmatter() {
  awk '
    /^---$/ { c++; if (c==1) in_fm=1; else if (c==2) exit; next }
    in_fm { print }
  '
}
```

frontmatter が存在しない場合は `permissionDecision: "ask"` で人間判断を促す（新規作成途中の可能性があるため。SKILL.md でないファイルは「1. 検査対象判定」で既に素通ししている）。

### 4. 必須フィールドの検査

frontmatter 内に以下が存在するか確認:

- `^name:` で始まる行
- `^description:` で始まる行（**多行 YAML 対応**: `description: |` や `description: >` の literal/folded block も検出する）

いずれかが欠落 → `permissionDecision: "deny"` + `permissionDecisionReason` で書き込み阻止

### 5. description 値の抽出（多行 YAML 対応）

```bash
extract_description() {
  awk '
    /^description:/ { in_desc=1 }
    in_desc && /^[a-zA-Z_-]+:/ && !/^description:/ { exit }
    in_desc { print }
  '
}
```

`description:` で始まる行から、次の非インデント YAML key 行の直前までを取得。

### 6. トリガー語の検査

**`disable-model-invocation: true` の skill は本検査を免除する**（`shared/scripts/hook-lint-skill-frontmatter.sh:L94-L101`）。description が listing に載らず Claude からも起動されないため、トリガー語（Claude の自動選択精度を上げるための記述）を強制する意味がない。

`user-invocable: false` は**免除しない**。listing には載り Claude からも起動されうるので、トリガー語は依然として意味を持つ。

免除されない skill について、description 値（多行含む）に以下のいずれかのキーワードが含まれるか:

```
時に|する時|使用|呼び出|キーワード|トリガー|when |trigger|use this|use when
```

含まれなければ `permissionDecision: "ask"` で人間判断を促す（deny ではない、軽い warning）。

**Codex では `ask` を `deny` に変える。** Codex は `ask`（確認プロンプト）に未対応で、未対応の値は hook の失敗として扱われ操作が続行する（= ガードが黙って開く）。入力に `turn_id` があれば Codex（Claude Code の入力には無い）と見なし、`ask` を返す箇所（frontmatter なし・トリガー語なし・前処理の失敗）はすべて `deny` で返して、理由の先頭に `[要確認]` を付ける。判定は hook 内の `decide_ask_or_deny()` で行い、必須フィールド欠落の `deny` は元から `deny` なので変わらない。`verify-skills.sh` の check 7(1) が、この関数の存在と、関数を通さない `ask` の直書きが無いことを検査する。

## 出力 JSON フォーマット

Phase A `hook-block-tmp-commit.sh:L95-L103` と同じ公式 `hookSpecificOutput` 形式:

### deny（必須フィールド欠落）

括弧内には欠けているフィールド名が入る（例: `description`、両方なら `name description`）。

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "SKILL.md frontmatter に必須フィールド (description) が欠落しています。詳細は shared/skills/_template/reference/skill-frontmatter-spec.md を参照。"
  }
}
```

### ask（トリガー語不足）

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": "SKILL.md description にトリガー語 (時に / する時 / 使用 / 呼び出 / キーワード / トリガー / when / trigger / use this / use when) が含まれていません。Claude の skill 自動選択精度に影響します。承認して保存しますか?"
  }
}
```

### 検査対象外 / pass

stdout 何も出力せず exit 0。

## 適合する SKILL.md の例

```yaml
---
name: my-skill
description: 何をする skill か。`/my-skill` で呼び出すキーワードを 2-3 個含める。
---
```

複数行 YAML 形式も適合（`outline` / `marp` / `blog` / `agent-memory` skill 等）:

```yaml
---
name: marp
description: |
  アウトラインから dresscode テーマ準拠の Marp スライドを生成する。
  「Marp」「スライド作成」「スライド生成」「プレゼン作成」等のキーワードで使用。
---
```

## 不適合な例

```yaml
---
description: 何かをする skill   # ← name: が無い → deny
---
```

```yaml
---
name: my-skill                   # ← description: が無い → deny
---
```

```yaml
---
name: my-skill
description: 何かをする skill    # ← トリガー語が無い → ask
---
```
