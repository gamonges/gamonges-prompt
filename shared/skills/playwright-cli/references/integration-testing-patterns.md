# Integration test reliability patterns

統合テスト（実装変更を実際の UI 操作で検証する作業）で再現性・信頼性を高めるための汎用テクニック集。`integration-test-scenario` / `integration-test-run` スキルから参照される。

## 1. 絶対パス実行（mise 等の shim 対策）

shim 経由の実行が失敗する場合、実バイナリを `find` で特定し絶対パスで実行する。

```bash
find ~/.local/share/mise/installs -name playwright-cli -type f
PWCLI="/path/to/resolved/playwright-cli"
```

`open` コマンドの出力を `| head` 等でパイプしない。SIGPIPE でブラウザプロセスが落ちる。

## 2. フィクスチャは標準ライブラリで生成

外部画像ライブラリを追加せず、標準ライブラリだけでテスト用ファイルを作る。

- PNG: zlib + struct で手組みする（最小構成の PNG バイナリを合成）
- サイズ超過検証用ファイル: `b'\x00' * (N * 1024 * 1024)` のパディングで生成する

## 3. network キャプチャは 1 コールに閉じる

`run-code` は呼び出しごとに独立クロージャのため、リスナ登録 → UI 操作 → wait → return を必ず 1 コールで完結させる。

```js
async page => {
  const cap = [];
  page.on('response', r => {
    const u = r.url();
    if (/<対象ドメイン\/パスパターン>/.test(u)) {
      let ct = '';
      try { ct = r.request().headers()['content-type'] || ''; } catch (e) {}
      cap.push({ m: r.request().method(), s: r.status(), u: u.slice(0, 80), ct: ct.slice(0, 28) });
    }
  });
  // …UI操作（open dialog → setInputFiles → submit 等）…
  await page.waitForTimeout(5000);
  return { cap };
}
```

注意: フィルタの正規表現を狭めすぎない。宛先が複数ある場合、共通の広めのパターンにするか、宛先ごとに複数パターンを OR で並べる（取りこぼしを防ぐ）。

## 4. 有効 ID 発見の 3 手（優先順）

1. `<a href>` 抽出（正規表現でメニュー項目を除外する）
2. onClick 行: 一覧の先頭データ行のセルを click → 遷移後の `page.url()` から取得する
3. 認証済みページから backend の list API を直接 fetch する（DOM に行が出ない場合）:
   ```js
   page.evaluate(() => fetch('<list-endpoint>', { credentials: 'include' }).then(r => r.json()))
   ```
   応答 shape は `Object.keys` で確認する。

汎用的な落とし穴: URL パラメータの大文字小文字を誤ると、厳密な enum パースでサーバーエラーになるケースがある。列挙値は定数定義ファイルで確認する。

## 5. エラーパスは `page.route` でモック

決定的に再現できる。使用後は必ず `unroute` する。

```js
await page.route('<対象パターン>', r => r.fulfill({
  status: 400, contentType: 'application/xml', body: '<Error><Code>...</Code></Error>'
}));
// …実行→トースト文言 assert…
await page.unroute('<対象パターン>');
```

## 6. UI 駆動不能な経路 → 対象関数を直接実行して再現

動的 import 等でコンポーネントが mount せず UI 操作で辿れない経路は、その処理を担う関数/API リクエストを source で特定し、同じパラメータで手動実行して検証する（UI を介さず実処理の契約を直接検証する）。
