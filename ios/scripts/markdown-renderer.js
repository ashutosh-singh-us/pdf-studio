// Markdown preview for the iOS app. Same pipeline and settings as the desktop app (src/app.js):
// marked (GFM) -> DOMPurify -> heading ids, link handling, highlight.js.
// Swift calls window.pdfstudio.render(text); results go back through webkit.messageHandlers.md.
(() => {
  const post = (msg) => { try { window.webkit.messageHandlers.md.postMessage(msg); } catch {} };
  const parser = new marked.Marked({ gfm: true, breaks: false });
  const view = document.getElementById('view');

  // Relative image paths can't be loaded (the app only has access to the .md file itself).
  DOMPurify.addHook('afterSanitizeAttributes', (node) => {
    if (node.tagName !== 'IMG') return;
    const src = node.getAttribute('src') || '';
    if (!/^(https:|data:image\/)/i.test(src)) { node.setAttribute('data-src', src); node.removeAttribute('src'); }
  });

  const slugify = (t) => t.toLowerCase().trim().replace(/[^\p{L}\p{N}\s_-]/gu, '').replace(/\s+/g, '-') || 'section';
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };

  function render(text, keepScroll) {
    const range = document.documentElement.scrollHeight - innerHeight;
    const keep = keepScroll && range > 0 ? scrollY / range : 0;
    let body = String(text).replace(/^﻿/, ''), front = null;
    const fm = /^---[ \t]*\r?\n([\s\S]*?)\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/.exec(body);
    if (fm) { front = fm[1]; body = body.slice(fm[0].length); }
    let html = '';
    try { html = parser.parse(body); } catch (e) { html = ''; }
    view.innerHTML = DOMPurify.sanitize(html, {
      FORBID_TAGS: ['style', 'form', 'button', 'textarea', 'select', 'iframe', 'object', 'embed'],
      FORBID_ATTR: ['style'],
    });
    if (front) {
      const d = el('details', 'frontmatter'); d.append(el('summary', null, 'Document properties'), el('pre', null, front));
      view.prepend(d);
    }
    const used = new Map(), outline = [];
    for (const h of view.querySelectorAll('h1,h2,h3,h4,h5,h6')) {
      const base = slugify(h.textContent);
      const n = used.get(base) || 0;
      used.set(base, n + 1);
      h.id = n ? `${base}-${n}` : base;
      if (+h.tagName[1] <= 4) outline.push({ id: h.id, level: +h.tagName[1], title: h.textContent.trim() });
    }
    for (const a of view.querySelectorAll('a[href]')) {
      const href = a.getAttribute('href');
      if (href.startsWith('#')) { try { a.dataset.anchor = decodeURIComponent(href.slice(1)); } catch { a.dataset.anchor = href.slice(1); } }
    }
    for (const img of view.querySelectorAll('img')) {
      if (img.dataset.src == null) continue;
      const name = (img.dataset.src.split(/[?#]/)[0].split(/[\\/]/).pop()) || 'image';
      img.replaceWith(el('span', 'img-missing', `\u{1F5BC} ${img.alt || name} (picture not loaded)`));
    }
    for (const t of view.querySelectorAll('table')) { const w = el('div', 'table-wrap'); t.replaceWith(w); w.append(t); }
    for (const code of view.querySelectorAll('pre code')) {
      const lang = ([...code.classList].find((c) => c.startsWith('language-')) || '').slice(9);
      try {
        if (lang && hljs.getLanguage(lang)) hljs.highlightElement(code);
        else if (!lang && code.textContent.length < 5000) {
          const r = hljs.highlightAuto(code.textContent);
          if (r.relevance > 5) { code.innerHTML = r.value; code.classList.add('hljs'); }
        }
      } catch {}
    }
    // Task-list checkboxes are display-only.
    for (const box of view.querySelectorAll('input[type=checkbox]')) box.disabled = true;
    const words = (body.match(/[\p{L}\p{N}]+/gu) || []).length;
    if (keep) scrollTo(0, keep * (document.documentElement.scrollHeight - innerHeight));
    post({ type: 'rendered', outline, words });
  }

  document.addEventListener('click', (e) => {
    const a = e.target.closest('a[data-anchor]');
    if (!a) return;
    e.preventDefault();
    const t = document.getElementById(a.dataset.anchor);
    if (t) t.scrollIntoView({ block: 'start', behavior: 'smooth' });
  });

  window.pdfstudio = {
    render,
    scrollToHeading(id) { const t = document.getElementById(id); if (t) t.scrollIntoView({ block: 'start', behavior: 'smooth' }); },
    setZoom(z) { document.documentElement.style.setProperty('--md-zoom', String(z)); },
  };
  post({ type: 'ready' });
})();
