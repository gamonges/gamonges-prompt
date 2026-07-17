---
name: coupling-anatomy
description: Khononovの結合モデル(統合強度×距離×変動性、バランス公式)の判定基準・訳語表・事実/推測方針・標準出力フォーマットを提供する基盤スキル。coupling-audit/coupling-plan-diff/coupling-precheck/coupling-gateが判定基準として参照する。単独では呼び出さない。
user-invocable: false
---

> **SSOT 宣言**: 結合分析の判定基準は本スキルが single source of truth。`coupling-audit` / `coupling-plan-diff` / `coupling-precheck` / `coupling-gate` の4つの目的別スキルはここを名指し参照し、判定基準を再宣言しない。判定基準を更新する場合は本ファイルのみを変更する。

出典: Vlad Khononov 著『Balancing Coupling in Software Design』（Addison-Wesley Signature Series, 2024）/ 日本語版『ソフトウェア設計の結合バランス』（島田浩二訳、Impress）。コンパニオンサイト coupling.dev を一次情報とする。

## 3軸の判定基準

### 統合強度（Integration Strength）

コンポーネント間でどれだけの知識が共有されているかを表す。弱→強の4段階（順序の根拠: 共有知識の量 × 知識の明示性。コントラクトが最少・最明示、侵入が最多・最暗黙=最も脆い）。

| レベル | 定義 | 判定の手掛かり |
|---|---|---|
| コントラクト結合 | 実装詳細・機能要件・モデルの知識をすべてカプセル化した明示的な境界のみを共有する | Façade / Open-host service・Published Language(DDD) / Anti-corruption Layer(DDD) / DTO を介した呼び出し |
| モデル結合 | ドメインモデルの知識を共有する。モデルが変わると結合先すべてが変わる | 同一のドメインオブジェクト/エンティティを複数コンポーネントが直接扱っている |
| 機能結合 | 機能要件の知識を共有する。極端な例は重複実装（同一ビジネスルールをフロントエンド/バックエンド双方に実装） | 同じビジネスルールが2箇所以上に実装されている、または暗黙のプロトコル手順に依存している |
| 侵入結合 | private interface（private object・内部DB等）への依存。侵入された側の作者が統合の存在自体を知らないことすらある | 他モジュールの内部実装・非公開API・内部テーブルへ直接アクセスしている |

### 距離（Distance）

単一尺度ではなく複合概念。3つの側面から評価する。

1. **コード上の物理的距離**: `Methods → Objects → Namespaces/Packages → (Micro)Services → Systems` の順に遠くなる（変更コストが増大する）
2. **社会技術的距離**: 同一チームが保守しているか、別チームかという組織構造の影響
3. **ランタイム結合**: 同期/非同期。**注意**: 非同期化はライフサイクル結合を減らすが、統合強度そのものは減らさない。「非同期化 = 疎結合」という単純化は誤り

### 変動性（Volatility）

そのコンポーネントが将来変更を必要とする確率。高いほど、統合強度×距離の設計の巧拙が「痛み」として顕在化する。

- **本質的変動性（Essential Volatility）**: ドメイン本質に起因する変化確率
- **偶発的変動性（Accidental Volatility）**: 統合強度・距離の管理不全が生む見かけ上の頻繁な変更。設計の悪さが原因であり、コミット頻度だけで変動性を測ると誤る（逆に「変更されない」ことも必ずしも安定を意味しない）

DDDサブドメイン分類との対応（参考。3段階の厳密な区分は一次情報で未確証）:

- **コアサブドメイン**: 最も変動性が高い（競争優位の源泉として継続的に最適化される）
- **サポーティング / ジェネリックサブドメイン**: コアよりずっと低い

## バランス判定式

### 2次元（統合強度 × 距離）

```
MODULARITY = STRENGTH XOR DISTANCE
COMPLEXITY = STRENGTH AND DISTANCE
```

| | Low Distance | High Distance |
|---|---|---|
| **Low Strength** | Low Cohesion（低凝集・Complexity） | Loose Coupling（疎結合・Modularity） |
| **High Strength** | High Cohesion（高凝集・Modularity） | Tight Coupling（密結合・Complexity） |

対角線（Low-Low, High-High）= 望ましくない Complexity。逆対角線（Low-High, High-Low）= 望ましい Modularity。

### 3次元（+ 変動性）

```
BALANCE = (STRENGTH XOR DISTANCE) OR NOT VOLATILITY
```

統合強度×距離の組み合わせが悪い場合（AND=真、Tight Coupling相当）でも、対象の変動性が低ければ（もう変化しないレガシー等）実害がなくバランスが取れているとみなせる。変動性が高いほど、統合強度/距離の設計判断の巧拙が痛みとして表面化しやすい。

> 定量的な10段階バランス公式（二次情報のみ、一次情報coupling.devでは未確認）は採用しない。上記のブール式（4象限 + 変動性）のみを判定軸とする。

## 日本語訳語 正典表

正典: 島田浩二訳『ソフトウェア設計の結合バランス』（Impress）。

| 英語 | 確定訳語 | 避けるべき表記 |
|---|---|---|
| Integration Strength | 統合強度 | 「結合強度」（旧来のcoupling概念と混同するため非推奨） |
| Distance | 距離 | — |
| Volatility | **変動性** | **「揮発性」（誤り。化学的含意で誤解を招く）** |
| Contract Coupling | コントラクト結合 | — |
| Model Coupling | モデル結合 | — |
| Functional Coupling | 機能結合 | — |
| Intrusive Coupling | 侵入結合 | — |

## 事実/推測の区別方針

実コードの grep/read 根拠がある記述は「事実」、根拠のない記述は「推測」と明記する。`plan.md` は意図、`git diff` は事実であり、事実を優先する。

## 標準出力フォーマット

すべての目的別スキルは以下の表構造（列名）で出力する。列の中身の性質（事実 or 推測）はスキルの対象により異なる（詳細は次項）。

### 結合関係テーブル

| # | 結合関係(呼び出し元→呼び出し先) | 統合強度 | 距離 | 変動性 | 判定 | 根拠 |
|---|---|---|---|---|---|---|
| 1 | ... | ... | ... | ... | ... | ... |

### 総合判定ブロック

```
MODULARITY: {true/false} — {根拠}
COMPLEXITY: {true/false} — {根拠}
BALANCE:    {true/false} — {根拠}
```

### 事実ベース/推測ベースの分岐

実コードが存在するスキル（`coupling-audit` / `coupling-plan-diff`）と、実装前の plan.md のみを対象とするスキル（`coupling-precheck` / `coupling-gate`）とでは、結合関係テーブルの**列の中身**が異なる。表の列構成（列名）自体は4スキル共通。

| | 事実ベース（`coupling-audit` / `coupling-plan-diff`） | 推測ベース（`coupling-precheck` / `coupling-gate`） |
|---|---|---|
| 「結合関係」列 | フルクラス名必須 | 想定モジュール名/概念名 |
| 「根拠」列 | `file:L{number}` | `plan.md:L{number}` または `(推測)` タグ |

各目的別スキルの実行プロセスは、自身がどちらの変種を用いるかをこの表を名指しして参照する。

## reference/artifact-procedure.md について

`reference/artifact-procedure.md` は `coupling-plan-diff` が `--artifact` オプション指定時のみ参照する。他のスキルは無視してよい。
