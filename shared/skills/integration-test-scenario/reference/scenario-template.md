# 統合テストシナリオの出力テンプレート

`integration-test-scenario` スキルのフェーズ 4 が `./tmp/integration-test-scenario.md` に出力する際の骨子。

<!-- tmp-frontmatter: tmp/integration-test-scenario.md -->
```markdown
---
type: Integration Test Scenario
title: [対象機能名] の統合テストシナリオ
description: [検証する観点の要約を 1 文]
status: stable
---
# 統合テストシナリオ: [対象機能名]

## ① 観点一覧
| 観点ID | 観点名 | 説明 |
|--------|--------|------|

## ② 経路×観点の対応表
| 経路 | 観点1 | 観点2 | ... |
|------|-------|-------|-----|

## ③ 各経路のUI操作手順
### グループA: [UIパターン名]
共通手順: ...

| 経路 | 差分パラメータ(URL/endpoint等) |
|------|-------------------------------|

## ④ 判定基準の参照先
`shared/skills/integration-test-run/reference/judgment-checklist.md` を参照。

## 環境&データ確認結果（フェーズ3のログ）
- 疎通確認: ...
- フィクスチャ: ...
- 有効ID: ...
```
