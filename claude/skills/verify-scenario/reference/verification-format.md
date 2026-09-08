# verification.md フォーマット正典

`openspec/specs/<capability>/verification.md` の書式を定義する。本ファイルが唯一の正典で、`verify-scenario` / `verification-authoring` / `integration-test-scenario` / `redash-template.md` はここを参照する（各所にコピーを持たない）。

**なぜ 1 箇所に固定するか**: 1 つの Driving 行を「① 実装直後の検証 → ② QA 引き渡し前の観点 → ③ 本番監視クエリ」の 3 工程で使い回すため、行の形が変わると 3 箇所に波及する。

## 見出しは 5 つで固定する

| 見出し | 何を書くか | 対応する工程 |
|--------|-----------|-------------|
| `Preconditions` | seed コマンドと、それが作る状態。spec.md の GIVEN に対応 | ① seed の実行 / ② データ準備 |
| `Sub-features` | この capability がユーザーから見て何と何に分かれるか | ② 観点の分割単位 |
| `How to get to it` | 利用者の到達経路（画面名と URL） | ① 操作の起点 / ② 経路 |
| `Driving it` | 検証の最小単位。1 行 = 操作 → 観測可能な結果 → `Side effect:` | ①②③ すべて |
| `Gotchas` | 仕様として意図された例外・恒久的な不整合・既知の落とし穴 | ② 判定の前提 |

見出しの増減はしない。順序も上表のとおりに揃える（読む側が同じ場所を探せるようにするため）。

機械検査の対象は**存在だけ**で、順序は検査しない — `verification-lint.mjs` は 5 見出しのいずれかが欠けていれば error にする。

## テンプレート

````markdown
# <capability> Verification

最終更新: YYYY-MM-DD

## Preconditions
- seed: `seed:scenario <capability>/<scenario-name>`
- 作られる状態: <1〜3 行。spec.md の GIVEN に対応させる>

## Sub-features
- <ユーザーから見た機能の分かれ目>

## How to get to it
- <画面名> → <画面名>（`http://localhost:<port>/<path>`）

## Driving it
- [ ] <操作> → <観測可能な結果>
      Side effect: `SELECT <col> FROM <table> WHERE organization_id = :org AND <key> = :val;`
      → actual: `<実測値>` / expected: `<期待値>`

## Gotchas
- <意図された例外・既知の落とし穴>
````

## Driving 行の 3 点セット

1 行に 3 要素を必ず揃える。どれか 1 つでも欠けると、その行は 3 工程のいずれかで使えなくなる。

| 要素 | 役割 | ① 実装直後 | ② QA 引き渡し前 | ③ 本番監視 |
|------|------|-----------|----------------|-----------|
| 操作 | ユーザー経路上の WHEN | 実アプリを操作する | 手順書の操作ステップ | — |
| 観測可能な結果 | 画面・レスポンス上の THEN | 目視 / DOM 確認 | 判定基準 | — |
| `Side effect:` SQL + actual / expected | 副作用の読み戻し | SELECT を実行して照合 | 観点の裏取り | check_id へ写す |

### 制約

- **`Side effect:` の SQL は SELECT のみ**。INSERT / UPDATE / DELETE は書かない — 検証手順が状態を書き換えると、同じ行を 2 回実行した結果が変わり、③ の監視クエリへ写せなくなる
- **`organization_id` を必ず絞る**。クロステナントの読み出しを検証手順に持ち込まない。列名が出てくるだけでは絞り込みにならない（`SELECT organization_id FROM t;` は全テナントの読み出し）。`WHERE` / `AND` 句での比較として書く
  - **`OR` で結合しない**。`WHERE user_id = :u OR organization_id = :org` は絞り込みとして機能せず他テナントの行を返す。lint はこの形に warn を出す（正当な `OR` を含むクエリもありうるため error にはしない）
  - **例外**: グローバル設定・監査ログなど、そもそもテナント列を持たないテーブル。この場合だけ `no-tenant-filter: <理由>` を付けて明示的に免除する（次節）
- **未実行の行は先頭に `draft:` を付ける**。「一度も実行していない行」は成果物ではなく下書きなので、`draft:` が残ったまま完了報告しない
- **実行したら actual を転記して `draft:` を外す**。actual は実測値をそのまま書く（期待に丸めない）
- **1 エントリの中に空行を置かない**。空行はエントリの終わりを意味する。エントリを空行で分割すると、2 ブロック目の `Side effect:` が別扱いになり、テナント絞り込みの検査が及ばなくなる
- **`## Driving it` にエントリ以外の行を書かない**。注記は `## Gotchas` へ置く。エントリの外に置いた散文は lint が error にする（「注: 実行したら actual: を転記する」のような文が `actual:` の存在検査を満たしてしまい、検査を空文化させるため）

### `draft:` 行と実行済み行の違い

| | `Side effect:` | expected | actual |
|---|---|---|---|
| `draft:` 行（未実行） | 必須 | 必須 | **不要**（まだ測っていない） |
| 実行済み行 | 必須 | 必須 | 必須 |

未実行の行に actual を書けないのは当然なので、lint も `draft:` 行には actual を要求しない。逆に、`draft:` を外した行に actual が無ければ「実行したつもりで測っていない」状態なので error になる。

### テナント絞り込みの例外（`no-tenant-filter:`）

テナント列を持たないテーブル（グローバル設定・監査ログ等）を読む場合だけ、`organization_id` の絞り込みを免除できる。

**書き方**: `Side effect:` と**同じ行**に `no-tenant-filter: <理由>` を書く。理由は必須（マーカーだけでは免除されない）。

```
- [x] 監査ログと注文を確認
      Side effect: `SELECT COUNT(*) FROM audit_logs;` / no-tenant-filter: 監査ログはテナント横断
      → actual: `3` / expected: 3
      Side effect: `SELECT id FROM orders WHERE organization_id = :org;`
      → actual: `1` / expected: 1
```

**係る範囲は「その 1 本の `Side effect:`」だけ**。上の例では 1 本目のみ免除され、2 本目は従来どおり検査される。1 行に `Side effect:` を 2 本書いた場合も、免除されるのはマーカーの直前にある 1 本だけ。

マーカーは対象の `Side effect:` の**後ろ**に書く（上の例と同じ形）。前に置くと直前の `Side effect:` が無いため、どれにも係らない。SQL が複数行に折り返す場合も、マーカーは `Side effect:` で始まる先頭行に置く。

**`draft:` とスコープが違う点に注意する**:

| マーカー | 置く場所 | 係る範囲 |
|---|---|---|
| `draft:` | エントリの 1 行目（チェックボックス直後） | そのエントリ全体 |
| `no-tenant-filter:` | `Side effect:` と同じ行 | その 1 本の SQL だけ |

`no-tenant-filter:` をエントリ単位にすると、1 本の逃げ道が同エントリの他の SQL の検査まで外してしまうため、意図的に非対称にしている。

## 記入例（架空の題材）

題材: 「アイテムに分類ラベルを 1 つだけ設定でき、ラベルを持たないアイテムは一括処理でスキップされる」。**実リポジトリの capability 名・テーブル名・URL・組織 ID は本ファイルに書かない**（それらは対象リポジトリの verification.md にのみ存在する）。

````markdown
# item-label-assignment Verification

最終更新: 2026-01-01

## Preconditions
- seed: `seed:scenario item-label-assignment/single-label-only`
- 作られる状態: アイテム 2 件（1 件はラベル候補値あり / 1 件は無し）、設定は既定値のまま

## Sub-features
- アイテムごとの分類ラベル種別の設定
- 設定に応じたラベル値の解決

## How to get to it
- 一覧 → 対象アイテム → 設定タブ → 分類ラベル（`http://localhost:5173/items/{itemId}/settings`）

## Driving it
- [ ] 設定タブを開く → 選択肢にそのアイテムが受け付ける種別のみが並ぶ
      Side effect: `SELECT accepted_label_types FROM item_setting
                    WHERE organization_id = :org AND item_id = :itemId;`
      → actual: `['TYPE_A', 'TYPE_B']` / expected: 受け付ける 2 種のみを含む
- [ ] 種別 A を選んで保存する → 選択が反映される（1 つだけ選択・優先順位なし）
      Side effect: `SELECT label_type FROM item_setting
                    WHERE organization_id = :org AND item_id = :itemId;`
      → actual: `TYPE_A` / expected: `TYPE_A`
- [ ] draft: 種別 A の値を持たないアイテムを含めて一括処理を実行する
      → 該当アイテムのみエラーになり、他は処理される（他種別へフォールバックしない）
      Side effect: `SELECT assigned_label FROM item
                    WHERE organization_id = :org AND setting_id = :settingId;`
      → expected: 種別 A の値を持つ 1 件のみ埋まる

## Gotchas
- 別用途のラベル（照合用）は本設定とは独立に持つ。ここで指定しなかった種別が自動で照合用になるわけではない
- 組織全体の一括設定は将来対応。アイテムごとの設定のみが有効
````

## 書かないこと

| 書かないもの | 理由 |
|---|---|
| 実装詳細（クラス名・レイヤー責務・ファイルパス） | リファクタで即座に腐る。verification.md はユーザー経路と副作用だけを持つ |
| SELECT 以外の SQL | 上記「制約」参照 |
| `organization_id` を絞らないクエリ | 同上。テナント列を持たないテーブルのみ `no-tenant-filter:` で免除する |
| 判定語彙の定義（確度 / 合否の区分） | `verify-scenario/SKILL.md` が持つ。ここに複製すると区分名の二重管理になる |
| 検証結果の報告フォーマット | 同上 |

## expected の根拠を辿れるようにする

spec.md が存在しない capability では、`expected` の根拠が仕様書ではなく決着済みの Q&A や議事録にあることがある。その場合は根拠の識別子を行末または `Gotchas` に添える（`（#<番号>）` の形で、決着を辿れる識別子を書く）。根拠が辿れない `expected` は、逆流（verification.md → spec.md）の材料に使えない。

## lint

`node ~/.claude/skills/verify-scenario/scripts/verification-lint.mjs <path-to-verification.md>` で書式を検査する。検査するのは**書かれ方だけ**で、中身の妥当性（expected が仕様と合っているか）は検査しない。
