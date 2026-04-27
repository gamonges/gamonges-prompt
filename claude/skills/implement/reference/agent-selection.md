# Phase 2.5: エージェント選択（implement skill 補助）

プロジェクトタイプと変更内容に基づき、実装で使用する専門エージェントを決定する。

## プロジェクトタイプ検出
1. `package.json` の dependencies（`@nestjs/core` → Backend, `react` → Frontend）
2. CLAUDE.md のキーワード（"NestJS" / "Prisma" → Backend, "React" / "TanStack" → Frontend）
3. ディレクトリ構造（`v2/src/` → Backend, `src/apps/` → Frontend）

## エージェント選択マトリクス
| 変更内容 | 起動エージェント |
|---------|---------------|
| ドメイン層（entity/command/repository/value） | backend-developer（+ 新規 entity/aggregate 設計時は ddd-expert を追加） |
| Prisma スキーマ / マイグレーション / SQL | database-administrator + sql-pro |
| API 層（controller/dto/usecase） | backend-developer + api-designer |
| フロントエンド UI コンポーネント | frontend-developer + ui-designer（+ アーキテクチャ変更時は react-architect を追加） |
| デザインシステム（トークン定義、テーマ設定、コンポーネント基盤） | design-system-architect + ui-designer |

**「+ ... を追加」の判定基準**: plan.md のステップ記述に「設計」「アーキテクチャ」「新パターン」等のキーワードが含まれるか、または新規ファイル作成を伴う構造的変更か。

## 差分規模によるスケーリング
- **Small**（ステップの変更ファイル < 3）: メインエージェントが直接実装。専門エージェント不要
- **Medium**（3-8 ファイル）: メインエージェントがタスク分割し、1-2 専門エージェントを起動
- **Large**（> 8 ファイル）: メインエージェントが分割し、複数専門エージェントを並列起動

## 並列実行プロトコル（Medium/Large ステップ）

1. メインエージェントが上記マトリクスに基づきタスクを分割する
2. 各専門エージェントの担当ファイルを **排他的に** 割り当てる（同一ファイルの並列編集は原則禁止）
3. 各エージェントを `run_in_background: true` で並列起動する
4. 各エージェントの出力: `./tmp/step-{n}-{agent-name}-result.md`
5. 全エージェント完了後、結果マージプロトコル（下記）を実行する

## 結果マージプロトコル

マルチエージェント並列実装の結果を安全にマージする:

1. **排他的ファイル割当の検証**: 各エージェントが割り当て外のファイルを変更していないか確認
2. **ファイル間整合性チェック**: import パス、型定義、インターフェースの一致を検証
3. **型チェック**: IDE の型エラー表示や `tsc --noEmit` の部分実行で確認（L-2: `pnpm run typecheck` のフル実行は避ける）
4. **テスト実行**: 変更箇所に関連するテストスイートを実行
5. **問題検出時**: メインエージェントが修正。修正不能な場合は該当エージェントを再起動

worktree 使用時の追加手順:
- 各 worktree の変更を `git diff` で確認
- メインブランチに `git merge --no-ff` で明示的にマージ
- コンフリクト発生時はメインエージェントが解決
