---
name: verification-authoring
description: spec.md と verification.md の間で骨格を生成する。順流（spec → verification）・逆流（verification → spec）・archive 追従の確認、/verification-authoring 呼び出しで使用。
disable-model-invocation: true
---

> **`/verification-authoring` と明示して起動する。** 自然言語からは起動しない設定のため、「検証定義の骨格を作って」のような依頼は別の skill に流れる（無反応で終わるのではなく、有効な別実装が選ばれる）。

## パラメーター

`verification-authoring <capability>` — 対象 capability を指定する。省略時は変更差分が触れた capability を候補として提示し、方向（順流 / 逆流）と併せて確認する。

## ワークフロー上の位置付け

| 前工程 | 本コマンド | 後工程 |
|--------|-----------|--------|
| `/design`（verification.md の要否判定） | `/verification-authoring` 骨格生成 | `verify-scenario` で実行 → `draft:` 解消 |
| `verify-scenario` で `draft:` を解消済み | `/verification-authoring`（逆流） | `openspec validate` → `/spec-propose` |

## 書式の正典

`claude/skills/verify-scenario/reference/verification-format.md` に従う。**本 skill は書式を再定義しない**（5 見出し・Driving 行の 3 点セット・`draft:` 規約はすべて正典側にある）。

## 2 つの方向

| 方向 | 使う場面 | 生成物 |
|------|---------|--------|
| **順流**: spec.md → verification.md | spec が既にある capability | verification.md の骨格（全行 `draft:`） |
| **逆流**: verification.md → spec.md | spec が無い機能（openspec を使わずに開発された機能） | spec.md の Scenario |

**逆流が主経路。** spec が無い機能は現に存在し、その場合の仕様の正は決着済みの Q&A や議事録にある。verification.md を先に書いて実行し、実行済みの行から spec を起こす。

## 順流（spec.md → verification.md）

1. spec.md の各 Scenario を読み、`Preconditions`（GIVEN の具体値 → seed の引数）と `expected`（THEN）を**下書き**する
2. **WHEN と `How to get to it` は手書きに残す**（自動生成しない）— spec の WHEN は「どの操作をしたか」を抽象化していることが多く、実際のユーザー経路（画面名・URL）は spec からは導けない
3. ユーザー経路に露出しない Scenario は verification.md から除外する。除外の判断は人に促す（内部イベントや backfill は ① の対象外）
4. **生成した行にはすべて `draft:` を付ける** — 一度も実行していないので成果物ではない

## 逆流（verification.md → spec.md）

1. **実行済みの（`draft:` が外れた）Driving 行のみを対象にする**
2. 各行を Scenario へ写す:
   - `Preconditions` → GIVEN
   - 操作 → WHEN
   - 観測可能な結果 + `Side effect:` の expected → THEN
3. `expected` の根拠（Q&A 番号・議事録の識別子）を Scenario に添え、後から辿れるようにする
4. `openspec validate` を通す

**`draft:` のままの行から spec を書かない。** 未検証の記述を仕様に昇格させると、「仕様に書いてあるから正しい」という循環が生まれる。

逆流で作った Scenario は「GIVEN が seed 可能な具体値」「THEN が SELECT で読み戻せる観測値」であることが**構造的に保証される**（そうでない行は ① で実行できず `draft:` が外れないため）。順流で規約として要求するしかなかった性質を、逆流では手順が満たす。

## archive 追従

openspec の archive は `specs/<capability>/spec.md` のみをマージ対象にするため、**verification.md は自動追従しない**。

**手順**: spec.md の Requirement を変更した場合、同 capability の verification.md の該当 Driving 行を見直し、**変わった行に `draft:` を戻す**（期待値が変わった行は、実行済みという記録ごと無効になる）。

**検知**: `node ~/.claude/skills/verify-scenario/scripts/verification-lint.mjs <path>` が「spec.md の最終コミットが verification.md より新しい」を warn で出す（git のコミット時刻で比較する）。

### この検知が塞げない穴（2 つ）

| 穴 | なぜ塞げないか |
|---|---|
| 未コミットの変更 | 作業中の verification.md は「古い」と判定されるため、dirty ならスキップする設計にしてある（commit 前に lint を回す運用での偽陽性を避けるため） |
| **spec.md を直さず実装だけ変えた** | 比較対象が 2 つのファイルの時刻しか無いため、コードの変更は観測できない |

この 2 つは運用で埋まらない。追従が仕組みではなく手順である以上、**skill が起動されなければ追従しない**ことを弱点として引き受ける。恒久解は archive 処理そのものへ組み込むことだけで、それは対象リポジトリ側の skill を編集できる段階（チーム展開時）の作業になる。

## PUBLIC リポジトリの制約

本 skill に capability 名・テーブル名・URL・Q&A 番号・組織 ID を書かない。生成の**手順**だけを持ち、具体値は対象リポジトリの `openspec/specs/` 側にのみ置く。
