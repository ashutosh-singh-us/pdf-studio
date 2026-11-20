// Builds dist/PDF-Studio/ : one self-contained HTML app + installers.
// Usage:  npm run build   (after npm install)
import { readFileSync, writeFileSync, mkdirSync, rmSync, copyFileSync, existsSync, readdirSync, chmodSync } from 'node:fs';
import { join, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = dirname(fileURLToPath(import.meta.url));
const NM = join(ROOT, 'node_modules');
const OUT = join(ROOT, 'dist', 'PDF-Studio');
const read = (...p) => readFileSync(join(...p), 'utf8');

// Libraries come from node_modules (installed by npm). If a file isn't there,
// the build looks for it in a plain vendor/ folder (for computers without npm access).
const VENDOR = {
  pdfjs: 'pdfjs-dist/build/pdf.min.js',
  worker: 'pdfjs-dist/build/pdf.worker.min.js',
  pdflib: 'pdf-lib/dist/pdf-lib.min.js',
  md: ['marked/lib/marked.umd.js', 'dompurify/dist/purify.min.js', '@highlightjs/cdn-assets/highlight.min.js'],
};

// Code placed inside <script> must not contain "</script", "<script" or "<!--".
// These escapes mean the same thing inside JS strings and regular expressions.
function safeJs(code, name) {
  code = code
    .replace(/<\/(script)/gi, '<\\/$1')
    .replace(/<!--/g, '<\\x21--')
    .replace(/<(s)(cript)/gi, (_, s, rest) => '<\\x' + s.charCodeAt(0).toString(16) + rest);
  const low = code.toLowerCase();
  if (low.includes('</script') || low.includes('<script') || code.includes('<!--')) throw new Error('Could not make safe: ' + name);
  return code;
}
const lib = (p) => {
  const f = [join(NM, p), join(ROOT, 'vendor', basename(p))].find((x) => existsSync(x));
  if (!f) throw new Error(`Missing ${p}. Run "npm install", or put ${basename(p)} in the vendor folder.`);
  return safeJs(readFileSync(f, 'utf8'), p);
};

const LOGO = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect x="4" y="4" width="56" height="56" rx="14" fill="#d6402b"/><path d="M22 14h14l10 10v24a3 3 0 0 1-3 3H22a3 3 0 0 1-3-3V17a3 3 0 0 1 3-3z" fill="#fff"/><path d="M36 14v10h10" fill="#f6c3ba"/><path d="M25 41c4-4 5-12 8-12s1 9 4 9 3-3 5-3" fill="none" stroke="#d6402b" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/></svg>`;

const parts = {
  '__FAVICON__': 'data:image/svg+xml;base64,' + Buffer.from(LOGO).toString('base64'),
  '/*__CSS__*/': read('src', 'app.css'),
  '/*__PDFJS__*/': lib(VENDOR.pdfjs),
  '/*__PDFLIB__*/': lib(VENDOR.pdflib),
  '/*__MDLIBS__*/': VENDOR.md.map(lib).join('\n'),
  '/*__WORKER__*/': lib(VENDOR.worker),
  '/*__APP__*/': safeJs(read('src', 'app.js'), 'app.js'),
};
// One pass, so code that was just inserted is never searched for placeholders again.
const pattern = new RegExp(Object.keys(parts).map((k) => k.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&')).join('|'), 'g');
const html = read('src', 'index.html').replace(pattern, (m) => parts[m]);

rmSync(OUT, { recursive: true, force: true });
mkdirSync(join(OUT, 'app'), { recursive: true });
writeFileSync(join(OUT, 'app', 'PDF-Studio.html'), html);

// Icons are optional (make them with tools/icon-maker.html).
for (const f of ['pdf-studio.ico', 'PDFStudio.icns']) {
  if (existsSync(join(ROOT, 'assets', f))) copyFileSync(join(ROOT, 'assets', f), join(OUT, 'app', f));
  else console.warn(`  (no assets/${f} - the app will use a default icon)`);
}
// Installers: Windows scripts need CRLF line endings; macOS scripts must be executable.
for (const f of readdirSync(join(ROOT, 'installers'))) {
  let text = read('installers', f);
  if (/\.(bat|ps1)$/i.test(f)) text = text.replace(/\r?\n/g, '\r\n');
  writeFileSync(join(OUT, f), text);
  if (f.endsWith('.command')) chmodSync(join(OUT, f), 0o755);
}
if (existsSync(join(ROOT, 'README.md'))) copyFileSync(join(ROOT, 'README.md'), join(OUT, 'README.md'));

console.log(`Built ${join(OUT, 'app', 'PDF-Studio.html')} (${(html.length / 1e6).toFixed(2)} MB)`);
