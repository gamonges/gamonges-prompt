# Gotchas（テンプレート）

> 本ファイルはテンプレートの placeholder。新規 skill 作成時にコピーして使用する。
> 運用ルールは SKILL.md 末尾の Gotchas セクションを参照。

## 記入フォーマット

各 gotcha は以下のテンプレートで追記する:

```markdown
### {YYYY-MM-DD} - {短いタイトル}

**現象**: 何が起きたか（再現条件を含む）

**回避**: どう対処したか / どう書けば良かったか

**再発回数**: N 回（3 回到達したら構造化昇格を検討）
```

## 記入例

### 2026-05-18 - playwright-cli の screenshot 取得時に viewport 指定漏れ

**現象**: `browser_take_screenshot` を呼ぶと、CSS が responsive な場合に意図しないモバイル表示で撮影される。viewport を明示しないと default が小さい。

**回避**: 必ず `browser_resize` で `{width: 1440, height: 900}` を先に設定してから screenshot する。

**再発回数**: 1 回
