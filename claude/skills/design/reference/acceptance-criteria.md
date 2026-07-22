# 受入条件（Acceptance Criteria）の記述ガイド

> SKILL.md フェーズ 5 の「受入条件」セクションを Given/When/Then 形式で記述するためのテンプレと記入例。
> `/review-plan` / `/review` のチェックリストとして活用される。

## 基本フォーマット

各受入条件は以下のいずれかのサブフォーマットを採用する:

### A. Given / When / Then 形式（推奨：ユーザーシナリオ / API 動作）

```markdown
- [ ] **AC-1**: ユーザーが {状況} で {操作} すると、{期待結果} になる
  - **Given**: 前提条件（データ状態、ログイン状態、画面遷移など）
  - **When**: 操作（クリック、API 呼出、フォーム送信など）
  - **Then**: 期待結果（画面表示、レスポンス、状態変化など）
  - **検証ステップ**: テストケース名や手動確認手順
```

### B. テストケース名 / 期待出力 形式（推奨：単体テスト・関数レベル）

```markdown
- [ ] **AC-2**: `functionName(input)` が `expectedOutput` を返す
  - **テストケース**: `tests/unit/foo.test.ts:L42` の `it("describes behavior")`
  - **期待出力**: `{ status: 'ok', data: [...] }`
  - **異常系**: 入力が空 → throws `ValidationError`
```

### C. チェックリスト形式（軽量、定型的な確認）

```markdown
- [ ] **AC-3**: `./tmp/plan.md` に Acceptance Criteria セクションが存在
- [ ] **AC-4**: 各 AC が Given/When/Then または テストケース形式で記述されている
- [ ] **AC-5**: 確信度サマリの low ステップに検証ステップが併記されている
```

## 記入例

### 例 1: 新規 API エンドポイント

```markdown
## 受入条件（Acceptance Criteria）

- [ ] **AC-1**: 認証済みユーザーが POST /api/users に有効な body を送ると、201 Created で作成された user を返す
  - **Given**: ユーザーは有効な session トークンを持つ
  - **When**: `POST /api/users` に `{ name, email, role }` を送信
  - **Then**: 201 Created + body に `{ id, name, email, role, createdAt }` が含まれる
  - **検証ステップ**: `tests/e2e/users.spec.ts` の `creates user with valid body` が green

- [ ] **AC-2**: email が重複している場合、409 Conflict を返す
  - **Given**: 既に同じ email のユーザーが存在する
  - **When**: 同じ email で POST /api/users
  - **Then**: 409 Conflict + body に `{ error: 'EMAIL_ALREADY_EXISTS' }` が含まれる
  - **検証ステップ**: `tests/e2e/users.spec.ts` の `rejects duplicate email` が green
```

### 例 2: フロントエンドの新規コンポーネント

```markdown
## 受入条件（Acceptance Criteria）

- [ ] **AC-1**: `<UserCard user={mockUser} />` が user.name と user.email を表示する
  - **テストケース**: `tests/UserCard.test.tsx:L20` の `displays user info`
  - **期待出力**: DOM に `mockUser.name` と `mockUser.email` のテキストが存在

- [ ] **AC-2**: avatar クリックで `onAvatarClick` callback が呼ばれる
  - **Given**: `<UserCard user={mockUser} onAvatarClick={mockFn} />` がレンダリングされている
  - **When**: avatar img を click
  - **Then**: `mockFn` が `mockUser` を引数に 1 回呼ばれる
  - **検証ステップ**: `tests/UserCard.test.tsx` の `invokes onAvatarClick` が green
```

### 例 3: 設定・hook 追加

```markdown
## 受入条件（Acceptance Criteria）

- [ ] **AC-1**: `claude/settings.json` に `hooks.PreToolUse[2]` が存在し、matcher が `"Edit|Write|MultiEdit"` である
  - **検証ステップ**: `jq '.hooks.PreToolUse[2].matcher' claude/settings.json` が `"Edit|Write|MultiEdit"` を返す

- [ ] **AC-2**: name フィールドが欠落した SKILL.md を Edit で書き込もうとすると、permissionDecision: deny が返る
  - **Given**: `/tmp/test-skill/SKILL.md` に `name:` が無い content
  - **When**: Claude Code から Edit ツールでこのファイルを編集
  - **Then**: hook script が `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",...}}` を出力し、書き込みが阻止される
  - **検証ステップ**: `echo '{...}' | bash claude/scripts/hook-lint-skill-frontmatter.sh` の手動確認
```

### 例 4: タイブレーク・優先順位判定ロジックの変更

```markdown
## 受入条件（Acceptance Criteria）

- [ ] **AC-1**: スコアが同点の場合、`registeredAt` が最も早い候補を優先して選ぶ
  - **テストケース**: `tests/tieBreak.test.ts` の `resolves tie by earliest registeredAt`
  - **期待出力**: 同点候補のうち `registeredAt` が最小の 1 件が返る

- [ ] **AC-2**: 対象データにおける同点候補の分布を実データで確認する
  - **検証ステップ**: `SELECT score, COUNT(*) FROM candidates GROUP BY score HAVING COUNT(*) > 1` を実データに対して実行し、同点が発生する件数・スコア帯を確認する
```

## 確信度サマリとの cross-link

`/design` で生成される確信度サマリの「検証ステップ」と本セクションのテストケースは可能な限り対応させる:

| 確信度サマリ | 受入条件 |
|-------------|---------|
| 確信度 low / 検証ステップ「スパイク実装」 | AC-N で「スパイク実装で確認した動作」を記述 |
| 確信度 medium / 検証ステップ「コード照合」 | AC-N で「期待されるコード変更箇所」を記述 |
| 確信度 high | 通常の AC のみで十分（特別な検証ステップ不要）|

## 注意事項

- すべての主要要件が AC でカバーされていること（要件カバレッジ検証）
- AC は **客観的に判定可能** な記述にする（曖昧な「使いやすいこと」「速いこと」は避ける）
- `/review-plan` / `/review` の機械的チェックに耐えるよう、**確認手段** を必ず記述する
- 同点候補の選ばれ方（優先順位・タイブレーク）を変える設計の場合、対象データでの重複件数・分布を実データで確認する AC を最低 1 つ含める
