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
| `disable-model-invocation` | `true` で Claude 自動呼出を禁止（手動 `/name` のみ）|
| `user-invocable` | `false` で `/` メニュー非表示（Claude は呼出可能）|
| `allowed-tools` | skill 有効時に承認なしで使える tool 一覧 |
| `model` | skill 専用モデル（session モデルを override）|
| `effort` | skill 専用 effort level（session effort を override）|
| `context` | `fork` で subagent context 実行 |
| `agent` | `context: fork` 時に使う subagent type |
| `hooks` | skill ライフサイクル限定の hooks |
| `paths` | この skill を自動 load するファイルの glob パターン |
| `shell` | `bash`（default）または `powershell` |

### `disable-model-invocation` と `user-invocable` の違い

両者は別物・両立可能:

- **`disable-model-invocation: true`** → `/` メニューに表示するが、Claude 自動呼出は禁止（例: `/commit` のような副作用ある操作）
- **`user-invocable: false`** → `/` メニューに表示しないが、Claude は呼出可能（例: バックグラウンド知識）
- 両方とも省略すれば user / Claude 両方から呼出可能（default）

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

`tool_input.tool_name` で分岐:

- **Write**: `tool_input.content` をそのまま検査
- **Edit**: 既存ファイルを読み、`tool_input.old_string` を `tool_input.new_string` で 1 回置換した結果を検査
- **MultiEdit**: 既存ファイルを読み、`tool_input.edits[]` を順次 1 回ずつ置換した結果を検査（W-B 対応で Python フォールバック推奨）

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

frontmatter が存在しない場合は exit 0（SKILL.md でない通常 md ファイルなど）。

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

description 値（多行含む）に以下のいずれかのキーワードが含まれるか:

```
時に|する時|使用|呼び出|キーワード|トリガー|when |trigger|use this|use when
```

含まれなければ `permissionDecision: "ask"` で人間判断を促す（deny ではない、軽い warning）。

## 出力 JSON フォーマット

Phase A `hook-block-tmp-commit.sh:L42-L51` と同じ公式 `hookSpecificOutput` 形式:

### deny（必須フィールド欠落）

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "SKILL.md に必須フィールド (name または description) が欠落しています。詳細は claude/skills/_template/reference/skill-frontmatter-spec.md を参照してください。"
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
