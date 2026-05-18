# UI 変更ステップの Verification 手順

> SKILL.md Phase 3.1 で UI 変更を伴うステップを始める時に参照する。
> Claude Code は CLI 環境で動作するため、UI 変更の検証は **`playwright-cli` skill** を介して行う。

## 適用判断

以下のいずれかに該当する場合、本手順を適用する:

- **画面の見た目が変わる**（コンポーネントの追加・削除・スタイル変更）
- **インタラクションが変わる**（クリック・フォーム入力・ナビゲーション）
- **CSS / Tailwind class の変更**を含む

該当しないケース（適用不要）:

- バックエンドのみの変更
- ロジック変更でも DOM 構造は維持される
- テストコードのみの変更

## 標準フロー

### 1. 実装前: 基準画像の取得

```bash
# /playwright-cli skill を経由して dev server を起動
/playwright-cli navigate {URL}
/playwright-cli resize 1440 900
/playwright-cli screenshot tmp/screenshots/before-{feature}.png
```

`tmp/screenshots/` ディレクトリは `.gitignore` 配下なのでコミット対象外。

### 2. 実装後: 期待結果との照合

```bash
/playwright-cli navigate {URL}
/playwright-cli resize 1440 900
/playwright-cli screenshot tmp/screenshots/after-{feature}.png
```

両画像を視覚的に比較し、以下を確認:

- 意図した変更が反映されているか
- 意図しない変更（崩れ・色違い・配置ズレ）が無いか
- レスポンシブ動作（モバイル / タブレット）が壊れていないか

### 3. インタラクション検証

```bash
# 主要なユーザーフローを実行
/playwright-cli click "button[data-testid='submit']"
/playwright-cli wait_for "text=Success"
/playwright-cli console_messages   # console error / warning の確認
/playwright-cli network_requests   # 期待 API が呼ばれているか確認
```

### 4. アクセシビリティの最低限確認

```bash
# WCAG 2.1 AA 準拠の最低限チェック
/playwright-cli snapshot  # accessibility tree を取得
```

確認項目:

- すべての interactive 要素にラベル / aria-label がある
- フォーム要素に対応する label がある
- 色のコントラストが 4.5:1 以上（通常テキスト）
- キーボード操作（Tab / Enter / Esc）が機能する

## 失敗時の対処

| 症状 | 対処 |
|------|------|
| screenshot が真っ白 / 部分的に欠ける | `wait_for` で要素のレンダリング完了を待つ |
| console error が出ている | error を Critical Issue として記録し、修正してから再撮影 |
| 期待 API が呼ばれていない | network_requests で実際の URL / method / payload を確認 |
| レスポンシブが崩れる | `resize` で各 breakpoint (375 / 768 / 1024 / 1440) で再確認 |

## 報告フォーマット

UI 検証の結果は実装ステップの「テスト方針」セクションに以下のように記載する:

```markdown
- テスト方針: UI 検証 — playwright-cli で before/after 撮影、主要インタラクション 3 件を確認
  - ✅ ボタンクリック → モーダル表示
  - ✅ フォーム送信 → 成功メッセージ
  - ✅ ESC キー → モーダル閉じる
  - ✅ console error なし、network 要求は POST /api/users のみ
```

## 注意事項

- **本リポジトリのような UI を持たないプロジェクトでは本手順は適用しない**（CLI / 設定ファイルのみの変更）
- 大規模な UI 変更（ページ全体の刷新）では visual regression test の自動化を別途検討
- アニメーション / トランジションは screenshot で捉えにくいため、video キャプチャまたは `wait_for` での状態遷移確認を併用
