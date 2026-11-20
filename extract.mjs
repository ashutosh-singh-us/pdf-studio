// Recreates the project's files from the build guide.
// Usage:  node extract.mjs BUILD-GUIDE.md
import { readFileSync, writeFileSync, mkdirSync, chmodSync } from 'node:fs';
import { dirname } from 'node:path';

const guide = readFileSync(process.argv[2] || 'BUILD-GUIDE.md', 'utf8').replace(/\r\n/g, '\n');
const block = /^\*\*File: `([^`]+)`\*\*\n\n(`{3,})[^\n]*\n([\s\S]*?)\n\2$/gm;
let n = 0;
for (const [, path, , body] of guide.matchAll(block)) {
  if (path.startsWith('/') || path.includes('..')) continue; // only write inside this folder
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, body + '\n');
  if (path.endsWith('.command')) chmodSync(path, 0o755);
  console.log('  wrote', path);
  n++;
}
console.log(`${n} files written.`);
