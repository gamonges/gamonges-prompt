# Backend / Database Reviewer チェックリスト（review skill 補助）

backend project の場合、以下のチェックリストを backend-reviewer / database-reviewer にインライン指示として渡す。これらは CI では検出困難な設計レベルの問題。`architecture.mdc` と `coding-rule.mdc` は全文ではなく要約を渡す。

## Backend-reviewer

### 必須チェック（全 diff サイズで適用）

**クロステナントセキュリティ**:
- テーブルアクセス時の organizationId フィルタ漏れ
- organizationId が Infrastructure 層で ApiContext から付与されているか
- JOIN/サブクエリの結合先にもフィルタが適用されているか

**エラーハンドリング設計**:
- 例外 throw 禁止、neverthrow の Result 型使用
- ErrorWithDisplayMessages 拡張クラスの 6 言語対応（en, ja, id, vn, th, zhCN）
- Command の of() ファクトリで入力値を検証し Result 型で返しているか

**Prisma / DB 制約**:
- 新規コードで OrThrow 系関数不使用（findFirstOrThrow, findUniqueOrThrow 等）
- DTO Optional 項目が null（undefined ではなく）
- any 型不使用

### 推奨チェック（Medium / Large diff で追加適用）

**アーキテクチャ整合性**:
- Domain → Infrastructure 依存がないか
- 別モジュールの内部実装を直接参照していないか（Adapter 経由か）
- Command → Query の依存がないか
- DTO/VO にビジネスロジックが混入していないか

**CQRS パターン検証**:
- Command Handler が 1 責務か
- Handler が tx: PrismaTx を引数で受け取っているか
- ビジネスルールが Entity に委譲され、Handler はオーケストレーションのみか

**Prisma / DB 制約（追加）**:
- 新規 View テーブル追加なし、View リレーションなし
- 新規テーブルの日付カラムに @db.Date
- exhaustive check で全エラーケースを処理

**Temporal データ整合性**（該当する場合のみ）:
- whereBi/whereUni フィルタの適用
- include 内での Temporal フィルタ適用
- setReadCursor / resetReadCursor の try/finally ペア

## Database-reviewer

**Prisma 固有チェック**:
- View テーブル新規追加・リレーション禁止（Prisma 6.13.0 以降非対応）
- Kysely の使用回避（メンテナンス性・可読性の観点）
- マイグレーションの安全性（既存データへの影響、ダウンタイム有無）
- 新規クエリに対応するインデックス設計
- JSON 型定義の整合性（prismaJson.d.ts との一致）
