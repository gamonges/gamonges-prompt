# `Side effect:` → 本番監視クエリへの変換規則

> **未実証**（作成完了・実証未了）。本変換規則は実際の Driving 行 1 本を変換して実行するまで確定しない。**実証前は下書きとして扱い、他の skill から正典として参照しない。** 実証が済んだらこのマーカーを外す（`verification.md` の `draft:` と同じ扱い）。
>
> 実証の前提条件: (a) 変換元となる実行済みの `Side effect:` が存在すること、(b) 監視クエリを実行できる環境への接続。

## なぜ変換が必要か（自明ではない）

同じ副作用を見るのに、① と ③ で SELECT の形が反転する。

| | ① 実装直後の検証 | ③ 本番監視 |
|---|---|---|
| 対象 | 1 組織の 1 行 | 全組織の違反行 |
| 問い | 「この値は期待どおりか」 | 「期待から外れた行が何件あるか」 |
| 結果 | actual = 実測値 / expected = 期待値 | actual = 違反件数 / expected = 0 |

① の SELECT をそのまま schedule に載せると、1 組織の 1 行しか見ない監視になる。

## 変換規則

1. **expected の否定を WHERE に移す** — 「期待どおりの行を取る」から「期待から外れた行を取る」へ反転させる
2. **`organization_id` で GROUP BY** — ① の `WHERE organization_id = :org` を絞り込みから集計軸へ移し、`scope` 列に出す
3. **`actual = COUNT(*)` / `expected = 0`** — 違反件数を actual、正常時の期待値を 0 に固定する。これで全 check が同じ形の合否判定になる
4. **`check_id` と `severity` を定数列として先頭に置く**

```sql
-- ① の形（1 組織の 1 行を読む）
SELECT <col> FROM <table>
WHERE organization_id = :org AND <key> = :val;
-- → actual: <実測値> / expected: <期待値>

-- ③ の形（全組織の違反数を数える）
SELECT
  '<check_id>'  AS check_id,
  '<SEVERITY>'  AS severity,
  organization_id::text AS scope,
  COUNT(*)      AS actual,
  0             AS expected,
  '<何が起きているかの説明>' AS detail
FROM <table>
WHERE <expected の否定>
GROUP BY organization_id
HAVING COUNT(*) > 0;
```

## 出力スキーマは 6 列で固定する

`check_id | severity | scope | actual | expected | detail`

複数の check を `UNION ALL` で 1 クエリに束ねられるようにするため、列とその順序を変えない。

## 先頭に健全性サマリ行を必ず出す

```sql
SELECT 'Z0_health_summary' AS check_id, 'INFO' AS severity,
       'all' AS scope, COUNT(*) AS actual, COUNT(*) AS expected,
       '母集団の件数。この行が出ないならクエリ自体が壊れている' AS detail
FROM <母集団>
UNION ALL
-- 以下、各 check
```

**理由**: 違反 0 件（健全）と、クエリが壊れて 0 行（何も見ていない）が、結果の見た目では区別できない。サマリ行が出ているかどうかが唯一の区別手段になる。`check_id` を `Z0_` で始めるのは、名前順に並べたとき末尾に来ないようにするため（先頭固定の意図を名前で示す）。

## `check_id` の命名

| カテゴリ | 何を守るか |
|---|---|
| A | 特定バグの回帰ガード（一度直した事象が再発していないか） |
| B | 取り込みパイプラインの健全性（入力が届いているか） |
| C | 判定結果の妥当性（導出された値が入力と整合するか） |
| D | 派生テーブル間の整合（同じ事実を持つ 2 つの表がずれていないか） |

`<カテゴリ><連番>_<何を見るか>` の形にする（例: `A3_stale_link_reappeared`）。Driving 行から起こした check は、根拠として元の capability 名を `detail` に含める。

## 性能

**「全期間を再集計して比較」ではなく「値そのものが実イベントとして存在するか」を等値で引く。**

再集計方式（期待値をその場で計算し直して実測と比較する）は母集団が育つほど遅くなり、監視の実行時間上限に当たる。等値方式（期待される行の存在／不在を条件で引く）はインデックスに載るため、同じ検査が桁違いに速く終わる。

実測の教訓: 再集計方式で実行時間の上限に当たったクエリを等値方式へ書き換えたところ、桁違いに速くなった事例がある。**変換時点で等値方式を選ぶ**（後から書き換えるより安い）。

## スコープ外

schedule の設定、通知先、アラート閾値の運用設計は本テンプレートの対象外。変換規則と出力スキーマだけを定義する。

## PUBLIC リポジトリの制約

本ファイルに実テーブル名・実際の `check_id`・データソース ID・クエリ ID を書かない。変換の**構造**だけを持つ。
