// 録画中の画面にテロップ・強調枠・ぼかしを重ねる。render.py overlay が先頭に
// `window.__ovConfig = {...};`（色とぼかしの式）を付けて overlay.js にする。
// playwright-cli の run-code で `page.context().addInitScript({path})` に渡して全ページへ注入する
// （HTML には埋めない）。使い方: window.__ov.telop(text) / hl(selectorOrText, pad, up) / clear() / log
(() => {
const cfg = window.__ovConfig || {};
const accent = cfg.accent || '#5fd3e6';
const emphasis = cfg.emphasis || '#ffd166';
const log = [];
const regs = [];
for (const p of (cfg.blur_patterns || [])) {
  try { regs.push(new RegExp(p, 'i')); } catch (_) { log.push({ type: 'badpattern', pattern: p }); }
}
const __init = () => {
  if (window.__ov) return;
  const root = document.createElement('div');
  root.id = '__ov_root';
  root.style.cssText = 'position:fixed;inset:0;pointer-events:none;z-index:2147483647';
  document.body.appendChild(root);
  const bar = document.createElement('div');
  bar.style.cssText =
    'position:absolute;left:50%;bottom:48px;transform:translateX(-50%);background:rgba(15,26,54,.92);color:#fff;' +
    'font:700 34px "Hiragino Sans",sans-serif;padding:18px 40px;border-radius:14px;border-left:10px solid ' + accent + ';' +
    'box-shadow:0 8px 30px rgba(0,0,0,.35);display:none;white-space:nowrap';
  root.appendChild(bar);
  const box = document.createElement('div');
  box.style.cssText =
    'position:absolute;border:5px solid ' + emphasis + ';border-radius:10px;box-shadow:0 0 0 9999px rgba(0,0,0,.28);' +
    'transition:all .35s ease;display:none';
  root.appendChild(box);
  const find = (q) => {
    try { const el = document.querySelector(q); if (el) return el; } catch (_) {}
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    let n;
    while ((n = walker.nextNode())) {
      if (n.textContent.trim() === q && n.parentElement && n.parentElement.offsetParent !== null) return n.parentElement;
    }
    return null;
  };
  window.__ov = {
    log,
    telop(t) { bar.textContent = t; bar.style.display = t ? 'block' : 'none'; },
    hl(q, pad = 10, up = 0) {
      let el = find(q);
      for (let i = 0; el && i < up; i++) el = el.parentElement;
      if (!el) { box.style.display = 'none'; log.push({ type: 'notfound', query: q }); return 'notfound'; }
      el.scrollIntoView({ block: 'center' });
      const r = el.getBoundingClientRect();
      Object.assign(box.style, { display: 'block', left: r.left - pad + 'px', top: r.top - pad + 'px', width: r.width + pad * 2 + 'px', height: r.height + pad * 2 + 'px' });
      return 'ok';
    },
    clear() { box.style.display = 'none'; bar.style.display = 'none'; },
  };
  // 個人情報の形にぼかしをかける。描画し直しに追従するため、定期と DOM の書き換え直後の両方で当て直す
  const blurAll = () => {
    if (!regs.length) return;
    const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    let n;
    while ((n = w.nextNode())) {
      const el = n.parentElement;
      if (!el || el.closest('#__ov_root')) continue;
      if (regs.some((r) => r.test(n.textContent))) el.style.filter = 'blur(6px)';
    }
  };
  setInterval(blurAll, 150);
  new MutationObserver(blurAll).observe(document.body, { childList: true, characterData: true, subtree: true });
  blurAll();
};
if (document.body) __init(); else document.addEventListener('DOMContentLoaded', __init);
})();
