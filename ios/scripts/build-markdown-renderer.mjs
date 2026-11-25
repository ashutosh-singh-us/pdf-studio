// Builds ios/PDFStudio/Resources/markdown.html: the offline Markdown preview page for the iOS app.
// Uses the same library versions as the desktop app (from the repo's node_modules).
// Usage (from the repo root):  npm install && node ios/scripts/build-markdown-renderer.mjs
import { readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const NM = join(ROOT, 'node_modules');
const read = (p) => readFileSync(p, 'utf8');

function safeJs(code, name) {
  code = code
    .replace(/<\/(script)/gi, '<\\/$1')
    .replace(/<!--/g, '<\\x21--')
    .replace(/<(s)(cript)/gi, (_, s, rest) => '<\\x' + s.charCodeAt(0).toString(16) + rest);
  const low = code.toLowerCase();
  if (low.includes('</script') || low.includes('<script') || code.includes('<!--')) throw new Error('Could not make safe: ' + name);
  return code;
}

const libs = ['marked/lib/marked.umd.js', 'dompurify/dist/purify.min.js', '@highlightjs/cdn-assets/highlight.min.js']
  .map((p) => safeJs(read(join(NM, p)), p)).join('\n');

// No network access except https images written in the document; scripts and styles are inline only.
const csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src https: data:";
const html = `<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="${csp}">
<style>${read(join(HERE, 'markdown-renderer.css'))}</style>
</head><body><article id="view" class="markdown-body"></article>
<script>${libs}</script>
<script>${safeJs(read(join(HERE, 'markdown-renderer.js')), 'markdown-renderer.js')}</script>
</body></html>
`;
const out = join(ROOT, 'ios', 'PDFStudio', 'Resources', 'markdown.html');
writeFileSync(out, html);
console.log(`Built ${out} (${(html.length / 1024).toFixed(0)} KB)`);
