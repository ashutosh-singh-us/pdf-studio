# Build PDF Studio from scratch: step-by-step guide

This guide rebuilds **PDF Studio** on your own computer, from an empty folder to an installed app. PDF Studio is a PDF reader and editor and a Markdown reader. It works on **Windows and macOS** and **needs no admin rights** at any step.

Every source file is included below. You can create the files automatically with a 20-line script (section 3), or copy them by hand.

**Time needed:** about 20–30 minutes.
**You need:** Node.js (installed without admin), a browser (Edge, Chrome or Brave), and an internet connection once to download the libraries. There's also an offline option in section 2.4.

---

## Contents

1. [How the app works](#1-how-the-app-works)
2. [Install the tools (no admin)](#2-install-the-tools-no-admin)
3. [Create the project files](#3-create-the-project-files)
4. [Download the libraries](#4-download-the-libraries)
5. [Make the icons (optional)](#5-make-the-icons-optional)
6. [Build the app](#6-build-the-app)
7. [Install it on Windows or Mac](#7-install-it-on-windows-or-mac)
8. [Test checklist](#8-test-checklist)
9. [Source code, with explanations](#9-source-code-with-explanations)
10. [Customizing and extending](#10-customizing-and-extending)
11. [Updating the libraries](#11-updating-the-libraries)
12. [Troubleshooting](#12-troubleshooting)
13. [Security and privacy notes](#13-security-and-privacy-notes)
14. [Licenses](#14-licenses)

---

## 1. How the app works

PDF Studio is **one HTML file** (about 2.3 MB). It contains all of its code and libraries. You open it in a browser, and the installers just create a shortcut that opens it in a clean "app window" (Chrome/Edge `--app` mode). Nothing runs on a server and no file ever leaves the computer.

```
                ┌────────────────────────── PDF-Studio.html ──────────────────────────┐
  PDF file ───► │ PDF.js ──► draws each page on a <canvas> + invisible text layer      │
                │            (selectable text, search) + form values                    │
                │                                                                       │
                │ Your edits are a list of shapes per page (text, ink, boxes, images),  │
                │ stored in PDF coordinates and drawn on a transparent overlay canvas.  │
                │                                                                       │
  Save ◄─────── │ pdf-lib ──► copies the pages, draws your edits into them, writes      │
                │            form values, saves a normal PDF                            │
                │                                                                       │
  .md file ───► │ marked (Markdown → HTML) ► DOMPurify (removes unsafe HTML)            │
                │ ► highlight.js (code colors) ► formatted preview                      │
                └───────────────────────────────────────────────────────────────────────┘
```

### The libraries

| Library | Version | What it does here | License |
|---|---|---|---|
| [PDF.js](https://mozilla.github.io/pdf.js/) (`pdfjs-dist`) | 3.11.174 | Reads and draws PDFs, text layer, search, form field info | Apache-2.0 |
| [pdf-lib](https://pdf-lib.js.org/) | 1.17.1 | Writes the saved PDF: pages, edits, form values | MIT |
| [marked](https://marked.js.org/) | 12.0.2 | Turns Markdown into HTML | MIT |
| [DOMPurify](https://github.com/cure53/DOMPurify) | 3.1.6 | Removes scripts and other unsafe HTML from Markdown | Apache-2.0 / MPL-2.0 |
| [highlight.js](https://highlightjs.org/) (`@highlightjs/cdn-assets`) | 11.9.0 | Colors code blocks in Markdown | BSD-3-Clause |

**Why PDF.js 3.11 and not 4 or 5?** Version 3.11 is the last one shipped as a classic script, which can be pasted straight into an HTML file and run from `file://`. Versions 4 and up are ES modules only and need more work (see section 11). We turn off the risky font code path with `isEvalSupported: false`; see section 13.

### Four tricks that make a single offline file work
1. **Libraries are pasted inline.** `build.mjs` replaces placeholders like `/*__PDFJS__*/` in `src/index.html` with the library code.
2. **The PDF.js worker runs from a "blob".** Browsers block loading worker files from `file://`. So the worker code is stored in a `<script type="text/plain">` tag, turned into a Blob URL, and handed to PDF.js as a ready-made `Worker` (`GlobalWorkerOptions.workerPort`).
3. **Script-safe escaping.** Inline code must never contain `</script`, `<script` or `<!--`, or the browser would cut the script short. The build rewrites them as `<\/script`, `<\x73cript` and `<\x21--`, which mean the same thing inside JavaScript strings and regular expressions.
4. **Edits are stored separately from the PDF.** Nothing is written into the PDF until you save. That's why undo, redo, moving and resizing are simple: they just change the list of shapes.

---

## 2. Install the tools (no admin)

### 2.1 Node.js (Windows, no admin)
1. Go to **https://nodejs.org/en/download** and choose the **LTS** version, **Windows**, **Standalone Binary (.zip)**. Pick **x64**, or **ARM64** on Snapdragon laptops.
2. Extract the zip and rename the extracted folder to `node`. Put it at `C:\Users\<you>\tools\node`, so that `node.exe` is directly inside that folder.
3. Add it to **your own** PATH. This doesn't need admin:
   - Start menu → type **"Edit environment variables for your account"** → select **Path** → **Edit** → **New** → `%USERPROFILE%\tools\node` → OK.
   - Or in PowerShell:
     ```powershell
     [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ";$env:USERPROFILE\tools\node", 'User')
     ```
4. Open a **new** Command Prompt or PowerShell window and check:
   ```bat
   node -v
   npm -v
   ```
> **PowerShell tip:** if `npm` says *"running scripts is disabled on this system"*, use **Command Prompt** instead, or type `npm.cmd` instead of `npm`. You can also run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`, which doesn't need admin.

### 2.2 Node.js (macOS, no admin password)
1. Find out your Mac type: Apple menu → **About This Mac**. "Apple M1/M2/M3/M4" means **arm64**; "Intel" means **x64**.
2. In **Terminal**, download and unpack Node into your home folder. Replace the version with the current LTS shown on nodejs.org; any version from 18 up works:
   ```bash
   mkdir -p ~/tools && cd ~/tools
   curl -LO https://nodejs.org/dist/v22.11.0/node-v22.11.0-darwin-arm64.tar.gz   # use darwin-x64 on Intel Macs
   tar -xzf node-v22.11.0-darwin-arm64.tar.gz
   mv node-v22.11.0-darwin-arm64 node
   echo 'export PATH="$HOME/tools/node/bin:$PATH"' >> ~/.zshrc
   source ~/.zshrc
   node -v && npm -v
   ```
   Downloading with `curl` in Terminal avoids macOS "downloaded from the internet" warnings.

### 2.3 Browser and editor
- **Browser:** Microsoft Edge comes with Windows. On a Mac, Google Chrome can be installed without admin: open the downloaded `.dmg` and drag Chrome into the **Applications folder inside your home folder** (`~/Applications`). Safari also works, but without the app-window mode.
- **Text editor (optional):** any editor works. Visual Studio Code has a **User Installer** for Windows (no admin). On a Mac, unzip it into `~/Applications`.

### 2.4 Computer without internet access (optional)
`npm install` needs the internet once. If the build computer can't reach the npm registry, get the six library files another way and put them in a folder named **`vendor`** inside the project. `build.mjs` looks there automatically.

**Option A: npm package files (recommended).** On any computer with Node and internet:
```bash
npm pack pdfjs-dist@3.11.174 pdf-lib@1.17.1 marked@12.0.2 dompurify@3.1.6 @highlightjs/cdn-assets@11.9.0
```
This creates five `.tgz` files. Copy them to the build computer. Unpack each one with `tar -xzf <file>.tgz` (`tar` is built into Windows 10/11 and macOS). Each unpacks into a folder called `package`, so unpack them one at a time. Copy these files into `vendor/`:

| File for `vendor/` | Path inside the package | Size (bytes) | SHA-256 |
|---|---|---|---|
| `pdf.min.js` | `package/build/pdf.min.js` | 320,004 | `5b5799e6f8c680663207ac5b42ee14eed2a406fa7af48f50c154f0c0b1566946` |
| `pdf.worker.min.js` | `package/build/pdf.worker.min.js` | 1,087,212 | `feabdf309770ed24bba31a5467836cdc8cf639c705af27d52b585b041bb8527b` |
| `pdf-lib.min.js` | `package/dist/pdf-lib.min.js` | 525,099 | `0f9a5cad07941f0826586c94e089d89b918c46e5c17cf2d5a3c6f666e3bc694f` |
| `marked.umd.js` | `package/lib/marked.umd.js` | 100,510 | `27ade2eccd4d58ab5edeb4f046eae71f204979547c4575fa11e294332d30a291` |
| `purify.min.js` | `package/dist/purify.min.js` | 21,496 | `c0845096a7c4a6741f362ac506c94c1c7d27dc603bcc1bf64a587f76f2dbe3a1` |
| `highlight.min.js` | `package/highlight.min.js` | 121,727 | `837a6fa5b0c736b52bbde2b2b6190f305da3fc9ed41681db5321507057b5c846` |

**Option B: direct download.** Open these addresses in a browser and save each file into `vendor/`. jsDelivr serves the npm files unchanged, so the checksums above should match. If one doesn't match, don't use that file.
```
https://cdn.jsdelivr.net/npm/pdfjs-dist@3.11.174/build/pdf.min.js
https://cdn.jsdelivr.net/npm/pdfjs-dist@3.11.174/build/pdf.worker.min.js
https://cdn.jsdelivr.net/npm/pdf-lib@1.17.1/dist/pdf-lib.min.js
https://cdn.jsdelivr.net/npm/marked@12.0.2/lib/marked.umd.js
https://cdn.jsdelivr.net/npm/dompurify@3.1.6/dist/purify.min.js
https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11.9.0/highlight.min.js
```
**Check a checksum:**
- Windows: `certutil -hashfile vendor\pdf.min.js SHA256`
- Mac: `shasum -a 256 vendor/pdf.min.js`

---

## 3. Create the project files

When you're done, the project looks like this:

```
pdf-studio/
├── BUILD-GUIDE.md            ← this guide
├── extract.mjs               ← creates all files below from this guide
├── package.json              ← library list + "npm run build"
├── build.mjs                 ← builds dist/PDF-Studio/
├── README.md                 ← user instructions (copied next to the app)
├── src/
│   ├── index.html            ← page layout, with placeholders for the libraries
│   ├── app.css               ← all styles (light, dark, print)
│   └── app.js                ← all app logic
├── tools/
│   └── icon-maker.html       ← makes the .ico / .icns icons in your browser
├── installers/
│   ├── Install on Windows.bat
│   ├── windows-install.ps1
│   ├── Uninstall on Windows.bat
│   ├── Install on Mac.command
│   └── Uninstall on Mac.command
├── assets/                   ← (optional) pdf-studio.ico, PDFStudio.icns
├── vendor/                   ← (only for the offline option in 2.4)
└── dist/PDF-Studio/          ← created by the build
```

### Option A: create everything automatically (recommended)
1. Create an empty folder, for example `Documents/pdf-studio`.
2. Save **this guide** into it as `BUILD-GUIDE.md`.
3. Create `extract.mjs` in the same folder with the code below. It's the only file you copy by hand.
4. Open a terminal **in that folder** and run:
   ```bash
   node extract.mjs BUILD-GUIDE.md
   ```
   It reads every block labeled **File: `…`** in this guide and writes it to that path. You should see `13 files written.`

   - Opening a terminal in the folder on Windows: in File Explorer, click the address bar, type `cmd` and press Enter.
   - On a Mac: right-click the folder in Finder → **New Terminal at Folder**. If you don't see it, type `cd ` in Terminal and drag the folder in.

**File: `extract.mjs`**

```js
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
```

### Option B: create the files by hand
Create each file from section 9 at the path shown in its **File:** label. Keep the folder names exactly as shown.

---

## 4. Download the libraries

In the project folder, run:
```bash
npm install --omit=optional
```
This reads `package.json` and downloads the five libraries into `node_modules/`. `--omit=optional` skips PDF.js's optional Node.js-only extras, which aren't needed in the browser and can fail to build on some systems.

Check that these six files exist. They're the only ones the build uses:
```
node_modules/pdfjs-dist/build/pdf.min.js
node_modules/pdfjs-dist/build/pdf.worker.min.js
node_modules/pdf-lib/dist/pdf-lib.min.js
node_modules/marked/lib/marked.umd.js
node_modules/dompurify/dist/purify.min.js
node_modules/@highlightjs/cdn-assets/highlight.min.js
```
`npm` may print "vulnerabilities" warnings. They refer to the older PDF.js version; section 13 explains how the app avoids that issue.

---

## 5. Make the icons (optional)

Without icons, the app uses the browser's icon. To get the red PDF Studio icon:
1. Double-click `tools/icon-maker.html`. It opens in your browser.
2. Click **Download pdf-studio.ico (Windows)** and **Download PDFStudio.icns (Mac)**.
3. Create a folder named `assets` in the project and move both downloaded files into it.

The page draws the logo itself and packs it into the Windows (`.ico`) and Mac (`.icns`) formats. No other software is needed.

---

## 6. Build the app

```bash
npm run build
```
You should see `Built …/dist/PDF-Studio/app/PDF-Studio.html (2.30 MB)`. The output folder contains:
```
dist/PDF-Studio/
├── app/PDF-Studio.html       ← the whole app
├── app/pdf-studio.ico        ← if you made icons
├── app/PDFStudio.icns        ← if you made icons
├── Install on Windows.bat, windows-install.ps1, Uninstall on Windows.bat
├── Install on Mac.command, Uninstall on Mac.command
└── README.md
```
**Quick test:** double-click `dist/PDF-Studio/app/PDF-Studio.html`. It opens in your browser. Drag a PDF or a `.md` file into the window.

Run `npm run build` again after every change to the files in `src/`.

---

## 7. Install it on Windows or Mac

### Windows
1. Open `dist\PDF-Studio` and double-click **`Install on Windows.bat`**.
2. It copies the app to `%LOCALAPPDATA%\PDF Studio`. It then creates **Start menu** and **Desktop** shortcuts that open the app in an Edge or Chrome app window, and launches it.
3. To remove it, run `Uninstall PDF Studio.bat` in `%LOCALAPPDATA%\PDF Studio`.

Because you built the files yourself, Windows normally won't show a SmartScreen warning. If it does, click **More info → Run anyway**.

### Mac
1. Open `dist/PDF-Studio` in Finder and double-click **`Install on Mac.command`**.
2. It creates **`~/Applications/PDF Studio.app`**, a tiny app bundle that opens the HTML in a Chrome, Edge or Brave app window, or in Safari if none of those is installed. It then opens the app. Drag it to the Dock if you like.
3. To remove it, run `Uninstall on Mac.command`.

If macOS says the script "can't be opened", run it from Terminal instead. This always works:
```bash
bash "dist/PDF-Studio/Install on Mac.command"
```

### Moving the build to another computer
Copy the whole `dist/PDF-Studio` folder by USB stick, a network share or a zip, then run the installer there. If you zip it on **Windows** and unzip it on a **Mac**, the `.command` files lose their "executable" flag. In that case, use the `bash "…command"` method above.

---

## 8. Test checklist

| Area | What to try | Expected |
|---|---|---|
| Open | Ctrl/⌘+O, or drag a PDF in | Pages appear, thumbnails on the left |
| Read | Scroll, zoom (Ctrl/⌘ + mouse wheel), Fit width | Sharp pages at every zoom |
| Text | Read mode: select text, copy | Text copies |
| Find | Ctrl/⌘+F, type a word, Enter | Matches highlighted, counter like `1/3` |
| Add text | **T**, click page, type, Esc | Text appears; double-click to edit |
| Draw / Highlight / Box / White-out | **D**, **H**, **R**, **W**, drag on page | Shape appears |
| Move / resize | **S**, drag a shape; drag its corner square | Moves / resizes; Delete removes it |
| Undo | Ctrl/⌘+Z, Ctrl/⌘+Y | Steps back and forward |
| Signature | Signature button → draw → Place | Signature placed, movable |
| Image | Image button or drag a PNG/JPG onto a page | Image placed |
| Pages | Rotate, ↑/↓, blank page, delete, drag thumbnails | Order and rotation change |
| Merge | **Merge** → choose another PDF | Its pages are added at the end |
| Forms | Open a fillable PDF → **Form** tab | Fields listed; values show on the page |
| Save | Ctrl/⌘+S, then reopen the saved file | Everything is still there; form fields still fillable |
| Password PDF | Open a protected PDF | Asks for password; saving keeps edits (pages become images) |
| Markdown | Open a `.md` file | Opens in **Preview**; Outline tab lists headings |
| Markdown edit | **Split**, type; Ctrl/⌘+S | Live preview; `.md` saved |
| Markdown PDF | **Print / Save as PDF** → "Save as PDF" | Clean PDF of the document |
| Dark mode | Switch your system to dark mode | App follows it |

---

## 9. Source code, with explanations

### 9.1 `package.json`
Lists the exact library versions. `"type": "module"` lets `build.mjs` use modern `import` syntax.

**File: `package.json`**

```json
{
  "name": "pdf-studio",
  "version": "1.1.0",
  "description": "Offline PDF reader/editor and Markdown reader in a single HTML file",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "node build.mjs"
  },
  "dependencies": {
    "@highlightjs/cdn-assets": "11.9.0",
    "dompurify": "3.1.6",
    "marked": "12.0.2",
    "pdf-lib": "1.17.1",
    "pdfjs-dist": "3.11.174"
  }
}
```

### 9.2 `build.mjs`: the build script
What it does, in order:
1. Reads `src/index.html`, `src/app.css` and `src/app.js`.
2. Loads the six library files from `node_modules`, or from `vendor/` as a fallback.
3. Escapes `</script`, `<script` and `<!--` so the code can sit safely inside `<script>` tags. See "Four tricks" in section 1.
4. Replaces each `/*__PLACEHOLDER__*/` in `index.html` with the matching code, in a **single pass**, so inserted code is never searched again.
5. Writes `dist/PDF-Studio/app/PDF-Studio.html`. It then copies the icons if they exist, the installers (giving Windows scripts CRLF line endings and making Mac scripts executable) and the README.

**File: `build.mjs`**

```js
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
```

### 9.3 `src/index.html`: the page layout
Contains everything you see: the top toolbar, the second bar (edit options, page tools, Markdown view switch), the sidebar (Pages / Form / Outline), the viewer area, and the dialogs (signature, page range, help).

How it's organized:
- `data-icon="…"`: the script fills in an SVG icon by that name.
- `class="pdf-only"` / `class="md-only"`: shown only in that mode (CSS hides the rest).
- `class="needs-doc"`: dimmed until a file is open.
- The build fills these placeholders: `/*__CSS__*/`, `/*__PDFJS__*/`, `/*__PDFLIB__*/`, `/*__MDLIBS__*/`, `/*__WORKER__*/`, `/*__APP__*/` and `__FAVICON__`. The worker sits in a `type="text/plain"` script so it isn't run on the page; it's started as a background worker instead.

**File: `src/index.html`**

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PDF Studio</title>
<link rel="icon" href="__FAVICON__">
<style>
/*__CSS__*/
</style>
</head>
<body>
<div id="app">
  <header class="toolbar" role="toolbar" aria-label="Main">
    <div class="group">
      <button class="btn" id="btnSidebar" title="Toggle sidebar" data-icon="sidebar"></button>
      <button class="btn label" id="btnOpen" title="Open a PDF or Markdown file (Ctrl+O)" data-icon="open">Open</button>
      <button class="btn label needs-doc pdf-only" id="btnAdd" title="Add pages from another PDF (merge)" data-icon="filePlus">Merge</button>
      <button class="btn label primary needs-doc" id="btnSave" title="Save (Ctrl+S)" data-icon="save">Save</button>
    </div>
    <div class="sep pdf-only"></div>
    <div class="group pdf-only">
      <button class="btn needs-doc" id="btnUndo" title="Undo (Ctrl+Z)" data-icon="undo"></button>
      <button class="btn needs-doc" id="btnRedo" title="Redo (Ctrl+Y)" data-icon="redo"></button>
    </div>
    <div class="sep pdf-only"></div>
    <div class="group tools pdf-only" id="tools">
      <button class="btn tool needs-doc" data-tool="read" title="Read &amp; select text (V)" data-icon="cursorText"></button>
      <button class="btn tool needs-doc" data-tool="select" title="Select / move / resize edits (S)" data-icon="pointer"></button>
      <button class="btn tool needs-doc" data-tool="text" title="Add text (T)" data-icon="type"></button>
      <button class="btn tool needs-doc" data-tool="ink" title="Draw (D)" data-icon="pen"></button>
      <button class="btn tool needs-doc" data-tool="highlight" title="Highlight area (H)" data-icon="highlighter"></button>
      <button class="btn tool needs-doc" data-tool="rect" title="Rectangle (R)" data-icon="square"></button>
      <button class="btn tool needs-doc" data-tool="whiteout" title="White-out / cover content (W)" data-icon="eraser"></button>
      <button class="btn tool needs-doc" data-tool="image" title="Insert image" data-icon="image"></button>
      <button class="btn tool needs-doc" data-tool="sign" title="Signature" data-icon="signature"></button>
    </div>
    <div class="sep"></div>
    <div class="group">
      <button class="btn needs-doc" id="btnZoomOut" title="Zoom out (Ctrl -)" data-icon="zoomOut"></button>
      <select id="zoomSel" class="needs-doc" title="Zoom">
        <option value="fitw">Fit width</option>
        <option value="fitp">Fit page</option>
        <option value="0.5">50%</option><option value="0.75">75%</option><option value="1">100%</option>
        <option value="1.25">125%</option><option value="1.5">150%</option><option value="2">200%</option>
        <option value="3">300%</option>
        <option value="custom" hidden>—</option>
      </select>
      <button class="btn needs-doc" id="btnZoomIn" title="Zoom in (Ctrl +)" data-icon="zoomIn"></button>
    </div>
    <div class="group pagenav pdf-only">
      <input id="pageNum" class="needs-doc" type="text" inputmode="numeric" value="" aria-label="Page number">
      <span id="pageCount" class="muted">/ 0</span>
    </div>
    <div class="spacer"></div>
    <div class="group search">
      <span class="search-box"><i data-icon="search"></i><input id="searchInput" class="needs-doc" type="search" placeholder="Find in document" aria-label="Find"></span>
      <span id="searchCount" class="muted small"></span>
      <button class="btn needs-doc" id="btnPrev" title="Previous match (Shift+Enter)" data-icon="chevUp"></button>
      <button class="btn needs-doc" id="btnNext" title="Next match (Enter)" data-icon="chevDown"></button>
    </div>
    <button class="btn" id="btnHelp" title="Help &amp; shortcuts" data-icon="help"></button>
  </header>

  <div class="subbar needs-doc-bar" id="subbar">
    <div class="group pdf-only" id="propsGroup">
      <span class="muted small" id="propsLabel">Read mode</span>
      <span class="props" id="propColorWrap">
        <span class="swatches" id="swatches"></span>
        <input type="color" id="propColor" title="Custom color">
      </span>
      <label class="props" id="propFontWrap"><select id="propFont" title="Font">
        <option value="Helvetica">Helvetica</option><option value="Helvetica-Bold">Helvetica Bold</option>
        <option value="Times">Times</option><option value="Times-Bold">Times Bold</option>
        <option value="Courier">Courier</option><option value="Courier-Bold">Courier Bold</option>
      </select></label>
      <label class="props" id="propSizeWrap" title="Font size"><span class="muted small">Size</span>
        <input type="number" id="propSize" min="4" max="144" step="1" value="14"></label>
      <label class="props" id="propWidthWrap" title="Line width"><span class="muted small">Line</span>
        <input type="range" id="propWidth" min="0.5" max="12" step="0.5" value="2"><span id="propWidthVal" class="small">2</span></label>
      <button class="btn label props danger" id="btnDelAnnot" data-icon="trash" title="Delete selected (Del)">Delete</button>
    </div>
    <div class="group md-only" id="mdBar">
      <div class="seg" role="group" aria-label="View">
        <button class="seg-btn" data-mdview="preview" title="Formatted view (Ctrl+E toggles source)">Preview</button>
        <button class="seg-btn" data-mdview="split" title="Edit with live preview">Split</button>
        <button class="seg-btn" data-mdview="source" title="Plain text">Source</button>
      </div>
      <span class="muted small" id="mdStats"></span>
    </div>
    <div class="spacer"></div>
    <div class="group md-only">
      <button class="btn label" id="btnMdPrint" title="Print, or choose “Save as PDF” in the print window (Ctrl+P)" data-icon="printer">Print / Save as PDF</button>
    </div>
    <div class="group pdf-only">
      <span class="muted small">Page</span>
      <button class="btn" id="btnRotL" title="Rotate page left" data-icon="rotL"></button>
      <button class="btn" id="btnRotR" title="Rotate page right" data-icon="rotR"></button>
      <button class="btn" id="btnMoveUp" title="Move page up" data-icon="arrowUp"></button>
      <button class="btn" id="btnMoveDown" title="Move page down" data-icon="arrowDown"></button>
      <button class="btn" id="btnBlank" title="Insert blank page after this one" data-icon="fileBlank"></button>
      <button class="btn" id="btnDelPage" title="Delete this page" data-icon="trash"></button>
      <button class="btn label" id="btnExtract" title="Extract or delete a range of pages" data-icon="scissors">Pages…</button>
      <button class="btn label" id="btnPrint" title="Preview / print the edited PDF" data-icon="printer">Print</button>
    </div>
  </div>

  <div class="main">
    <aside id="sidebar">
      <div class="tabs" role="tablist">
        <button role="tab" class="tab active pdf-only" data-tab="thumbs">Pages</button>
        <button role="tab" class="tab md-only" data-tab="outline">Outline</button>
        <button role="tab" class="tab pdf-only" data-tab="form">Form <span id="formBadge" class="badge" hidden></span></button>
      </div>
      <div class="tabpanel" id="thumbs" data-panel="thumbs"></div>
      <div class="tabpanel" id="formPanel" data-panel="form" hidden></div>
      <div class="tabpanel" id="outline" data-panel="outline" hidden></div>
    </aside>
    <section id="viewer" tabindex="-1">
      <div id="pages"></div>
      <div id="mdWrap" class="v-preview" hidden>
        <textarea id="mdSource" spellcheck="false" aria-label="Markdown source"></textarea>
        <div id="mdScroll"><article id="mdView" class="markdown-body"></article></div>
      </div>
      <div id="empty">
        <div class="empty-card">
          <div class="logo" data-icon="logo"></div>
          <h1>PDF Studio</h1>
          <p>Read, annotate, sign, fill forms and rearrange PDF pages, and read Markdown files.<br>Everything stays on this computer. Nothing is uploaded.</p>
          <button class="btn label primary big" id="btnOpen2" data-icon="open">Open a file</button>
          <p class="muted small">or drag &amp; drop a PDF or Markdown (.md) file anywhere in this window</p>
        </div>
      </div>
    </section>
  </div>
</div>

<div id="dropHint"><div>Drop a PDF or Markdown file to open it<br><span class="small">(a PDF dropped onto an open PDF is merged into it)</span></div></div>
<div id="toast" role="status" aria-live="polite"></div>

<input type="file" id="fileOpen" accept="application/pdf,.pdf,.md,.markdown,.mdown,.mkd,.mkdn,.mdwn,.mdtxt,.mdtext,.rmd,text/markdown,image/png,image/jpeg,image/gif,image/webp,image/svg+xml" multiple hidden>
<input type="file" id="fileAdd" accept="application/pdf,.pdf" multiple hidden>
<input type="file" id="fileImage" accept="image/png,image/jpeg,image/webp,image/gif" hidden>

<dialog id="sigDlg">
  <form method="dialog" class="dlg">
    <h2>Signature</h2>
    <div class="tabs small-tabs">
      <button type="button" class="tab active" data-sigtab="draw">Draw</button>
      <button type="button" class="tab" data-sigtab="type">Type</button>
      <button type="button" class="tab" data-sigtab="saved" id="sigSavedTab">Saved</button>
    </div>
    <div data-sigpanel="draw">
      <canvas id="sigPad" width="560" height="200"></canvas>
      <div class="row"><span class="muted small">Draw with mouse, trackpad or touch.</span><span class="spacer"></span><button type="button" class="btn label" id="sigClear">Clear</button></div>
    </div>
    <div data-sigpanel="type" hidden>
      <input type="text" id="sigText" placeholder="Type your name" autocomplete="name">
      <div id="sigTypePreview" class="sig-type-preview"></div>
    </div>
    <div data-sigpanel="saved" hidden>
      <div id="sigSavedList" class="sig-saved"></div>
    </div>
    <div class="row">
      <label class="small"><input type="checkbox" id="sigRemember" checked> Remember on this computer</label>
      <span class="spacer"></span>
      <span class="sig-colors"><button type="button" class="sw" data-sigcolor="#111827" style="background:#111827"></button><button type="button" class="sw" data-sigcolor="#1d4ed8" style="background:#1d4ed8"></button></span>
      <button value="cancel" class="btn label">Cancel</button>
      <button type="button" class="btn label primary" id="sigUse">Place signature</button>
    </div>
  </form>
</dialog>

<dialog id="pagesDlg">
  <form method="dialog" class="dlg">
    <h2>Pages</h2>
    <p class="muted small">Enter pages like <code>1-3, 5, 8-10</code>. This document has <b id="pagesDlgCount">0</b> pages.</p>
    <input type="text" id="pagesRange" placeholder="e.g. 1-3, 5">
    <div class="row">
      <button value="cancel" class="btn label">Cancel</button>
      <span class="spacer"></span>
      <button type="button" class="btn label danger" id="pagesDelete" data-icon="trash">Delete these pages</button>
      <button type="button" class="btn label primary" id="pagesExtract" data-icon="scissors">Save as new PDF</button>
    </div>
  </form>
</dialog>

<dialog id="helpDlg">
  <form method="dialog" class="dlg help">
    <h2>PDF Studio — quick guide</h2>
    <table>
      <tr><td><kbd>Ctrl/⌘ O</kbd></td><td>Open PDF</td></tr>
      <tr><td><kbd>Ctrl/⌘ S</kbd></td><td>Save</td></tr>
      <tr><td><kbd>Ctrl/⌘ Z</kbd> / <kbd>Ctrl/⌘ Y</kbd></td><td>Undo / Redo</td></tr>
      <tr><td><kbd>Ctrl/⌘ F</kbd></td><td>Find text</td></tr>
      <tr><td><kbd>Ctrl/⌘ +</kbd> / <kbd>−</kbd> / scroll</td><td>Zoom</td></tr>
      <tr><td><kbd>V</kbd> <kbd>S</kbd> <kbd>T</kbd> <kbd>D</kbd> <kbd>H</kbd> <kbd>R</kbd> <kbd>W</kbd></td><td>Read, Select, Text, Draw, Highlight, Rectangle, White-out</td></tr>
      <tr><td><kbd>Delete</kbd></td><td>Delete the selected edit</td></tr>
      <tr><td>Double-click text</td><td>Edit text you added</td></tr>
      <tr><td><kbd>Esc</kbd></td><td>Finish typing / deselect</td></tr>
    </table>
    <p class="small"><b>Editing existing text:</b> PDFs don't store editable paragraphs. To change printed text, use <b>White-out</b> to cover it, then add new text on top.</p>
    <p class="small"><b>Forms:</b> fillable fields appear in the <b>Form</b> tab of the sidebar. Click a field on the page in Read mode to jump to it.</p>
    <p class="small"><b>Pages:</b> drag thumbnails to reorder. Use Merge to append another PDF.</p>
    <p class="small"><b>Markdown:</b> .md files open in <b>Preview</b>. Switch to <b>Split</b> or <b>Source</b> to edit (<kbd>Ctrl/⌘ E</kbd> toggles), then save with <kbd>Ctrl/⌘ S</kbd>. To show pictures that use relative paths, open or drop the image files together with the .md file.</p>
    <p class="small muted">Everything runs locally in your browser. Your files never leave this computer.</p>
    <div class="row"><span class="spacer"></span><button class="btn label primary" value="ok">Close</button></div>
  </form>
</dialog>

<script>/*__PDFJS__*/</script>
<script>/*__PDFLIB__*/</script>
<script>/*__MDLIBS__*/</script>
<script type="text/plain" id="pdfjs-worker-src">/*__WORKER__*/</script>
<script>
/*__APP__*/
</script>
</body>
</html>
```

### 9.4 `src/app.css`: styles
- **Color tokens** live on `:root` (`--accent`, `--panel`, `--text`, …) and are redefined under `@media (prefers-color-scheme: dark)`. Change `--accent` to recolor the whole app.
- **Pages** stack four layers: the PDF canvas, a highlight canvas (`mix-blend-mode: multiply`, so highlighter colors don't hide text), the PDF.js text layer (invisible text you can select), and the overlay canvas for your edits.
- **Markdown** has a GitHub-like style (`.markdown-body`), code colors for highlight.js, and a `@media print` block. When printing, the block hides the toolbars and prints only the document, in light colors.
- At narrow widths, button labels collapse into icons.

**File: `src/app.css`**

```css
:root {
  --bg: #f3f4f6;
  --panel: #ffffff;
  --panel-2: #f9fafb;
  --border: #e3e5e9;
  --text: #1f2328;
  --muted: #6b7280;
  --accent: #d6402b;
  --accent-hover: #bd3521;
  --accent-soft: #fbe9e6;
  --viewer: #e6e8ec;
  --hover: #eef0f3;
  --focus: #2563eb;
  --shadow: 0 1px 2px rgba(16,24,40,.08), 0 4px 14px rgba(16,24,40,.08);
  --page-shadow: 0 1px 3px rgba(0,0,0,.18), 0 6px 18px rgba(0,0,0,.10);
  color-scheme: light;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #17191d; --panel: #1f2227; --panel-2: #24282e; --border: #33373e;
    --text: #e7e9ec; --muted: #9aa1ab; --accent: #ef5a43; --accent-hover: #f26f5a;
    --accent-soft: #3a2420; --viewer: #2a2d33; --hover: #2c3037; --focus: #60a5fa;
    --shadow: 0 1px 2px rgba(0,0,0,.4), 0 4px 14px rgba(0,0,0,.3);
    --page-shadow: 0 1px 3px rgba(0,0,0,.5), 0 6px 18px rgba(0,0,0,.35);
    color-scheme: dark;
  }
}
* { box-sizing: border-box; }
html, body { height: 100%; margin: 0; }
body {
  background: var(--bg); color: var(--text);
  font: 13px/1.4 system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  overflow: hidden;
}
#app { display: flex; flex-direction: column; height: 100%; }
button, input, select { font: inherit; color: inherit; }
.muted { color: var(--muted); }
.small { font-size: 12px; }
.spacer { flex: 1; }
[hidden] { display: none !important; }

/* Toolbars */
.toolbar, .subbar {
  display: flex; align-items: center; gap: 6px; flex-wrap: wrap;
  padding: 6px 10px; background: var(--panel); border-bottom: 1px solid var(--border);
}
.subbar { padding: 4px 10px; background: var(--panel-2); min-height: 40px; }
.group { display: flex; align-items: center; gap: 2px; }
.sep { width: 1px; align-self: stretch; background: var(--border); margin: 2px 4px; }
.btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 6px;
  height: 32px; min-width: 32px; padding: 0 7px; border-radius: 7px;
  border: 1px solid transparent; background: transparent; cursor: pointer; white-space: nowrap;
}
.btn svg { width: 18px; height: 18px; flex: none; }
.btn.label { padding: 0 10px; }
.btn:hover:not(:disabled) { background: var(--hover); }
.btn:focus-visible, input:focus-visible, select:focus-visible { outline: 2px solid var(--focus); outline-offset: 1px; }
.btn:disabled { opacity: .4; cursor: default; }
.btn.primary { background: var(--accent); color: #fff; }
.btn.primary:hover:not(:disabled) { background: var(--accent-hover); }
.btn.danger { color: var(--accent); }
.btn.big { height: 42px; padding: 0 20px; font-size: 15px; border-radius: 9px; }
.tool[aria-pressed="true"] { background: var(--accent-soft); color: var(--accent); border-color: color-mix(in srgb, var(--accent) 35%, transparent); }
select, input[type=text], input[type=number], input[type=search] {
  height: 30px; border: 1px solid var(--border); border-radius: 7px; background: var(--panel); padding: 0 8px;
}
#zoomSel { width: 104px; }
.pagenav input { width: 46px; text-align: center; margin-left: 6px; }
.pagenav span { margin-left: 4px; min-width: 36px; }
.search-box { position: relative; display: inline-flex; align-items: center; }
.search-box svg { position: absolute; left: 8px; top: 50%; transform: translateY(-50%); width: 15px; height: 15px; color: var(--muted); pointer-events: none; }
.search-box input { padding-left: 28px; width: 170px; }
#searchCount { min-width: 44px; text-align: right; }
.props { display: inline-flex; align-items: center; gap: 6px; margin-left: 8px; }
.swatches { display: inline-flex; gap: 4px; }
.sw { width: 20px; height: 20px; border-radius: 50%; border: 2px solid var(--panel); box-shadow: 0 0 0 1px var(--border); cursor: pointer; padding: 0; }
.sw[aria-pressed="true"] { box-shadow: 0 0 0 2px var(--focus); }
input[type=color] { width: 28px; height: 26px; border: 1px solid var(--border); border-radius: 6px; padding: 1px; background: var(--panel); cursor: pointer; }
#propSize { width: 58px; }
#propWidth { width: 90px; }
#propWidthVal { min-width: 22px; }
.no-doc .needs-doc { pointer-events: none; opacity: .4; }
.no-doc .needs-doc-bar { visibility: hidden; }

/* Layout */
.main { flex: 1; display: flex; min-height: 0; }
#sidebar { width: 210px; flex: none; display: flex; flex-direction: column; background: var(--panel); border-right: 1px solid var(--border); }
#sidebar.collapsed { display: none; }
.tabs { display: flex; gap: 2px; padding: 6px 6px 0; border-bottom: 1px solid var(--border); }
.tab { flex: 1; border: 0; background: none; padding: 7px 6px; cursor: pointer; border-bottom: 2px solid transparent; color: var(--muted); font-weight: 500; }
.tab.active { color: var(--text); border-bottom-color: var(--accent); }
.badge { display: inline-block; min-width: 18px; padding: 0 5px; border-radius: 9px; background: var(--accent); color: #fff; font-size: 11px; line-height: 18px; }
.tabpanel { flex: 1; overflow: auto; padding: 10px; }
#viewer { flex: 1; overflow: auto; background: var(--viewer); position: relative; outline: none; }
#pages { display: flex; flex-direction: column; align-items: center; gap: 16px; padding: 20px 24px 40px; min-width: min-content; }

/* Pages */
.page { position: relative; background: #fff; box-shadow: var(--page-shadow); flex: none; }
.page canvas { position: absolute; left: 0; top: 0; display: block; }
.page canvas.hl { mix-blend-mode: multiply; pointer-events: none; z-index: 1; }
.page canvas.ov { z-index: 3; pointer-events: none; }
.page .pnum { position: absolute; bottom: -16px; left: 0; right: 0; text-align: center; font-size: 11px; color: var(--muted); pointer-events: none; }
body.tool-active .page canvas.ov { pointer-events: auto; }
body.tool-select .page canvas.ov { cursor: default; }
body.tool-text .page canvas.ov { cursor: text; }
body.tool-ink .page canvas.ov, body.tool-highlight .page canvas.ov, body.tool-rect .page canvas.ov, body.tool-whiteout .page canvas.ov { cursor: crosshair; }
.page.field-hover { cursor: pointer; }
textarea.text-editor {
  position: absolute; z-index: 5; margin: 0; padding: 0; border: 0; resize: none; overflow: hidden;
  outline: 1.5px dashed var(--focus); outline-offset: 2px; background: rgba(255,255,255,.6);
  white-space: pre; line-height: 1.2; min-width: 20px;
}

/* pdf.js text layer */
.textLayer { position: absolute; text-align: initial; inset: 0; overflow: hidden; opacity: 1; line-height: 1;
  text-size-adjust: none; -webkit-text-size-adjust: none; forced-color-adjust: none; transform-origin: 0 0; z-index: 2; }
.textLayer span, .textLayer br { color: transparent; position: absolute; white-space: pre; cursor: text; transform-origin: 0% 0%; }
.textLayer span.markedContent { top: 0; height: 0; }
.textLayer ::selection { background: rgba(37, 99, 235, .3); }
.textLayer br::selection { background: transparent; }
.textLayer .endOfContent { display: block; position: absolute; inset: 100% 0 0; z-index: -1; cursor: default; user-select: none; }
.textLayer .endOfContent.active { top: 0; }
[data-main-rotation="90"] { transform: rotate(90deg) translateY(-100%); }
[data-main-rotation="180"] { transform: rotate(180deg) translate(-100%, -100%); }
[data-main-rotation="270"] { transform: rotate(270deg) translateX(-100%); }

/* Thumbnails */
#thumbs { display: flex; flex-direction: column; align-items: center; gap: 12px; }
.thumb { display: flex; flex-direction: column; align-items: center; gap: 4px; padding: 6px; border-radius: 8px; cursor: pointer; border: 2px solid transparent; position: relative; }
.thumb:hover { background: var(--hover); }
.thumb.current { border-color: var(--accent); }
.thumb .tbox { background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,.2); position: relative; }
.thumb canvas { display: block; }
.thumb .tlabel { font-size: 11px; color: var(--muted); }
.thumb.drop-before::before, .thumb.drop-after::after { content: ""; position: absolute; left: 4px; right: 4px; height: 3px; background: var(--focus); border-radius: 2px; }
.thumb.drop-before::before { top: -8px; }
.thumb.drop-after::after { bottom: -8px; }
.thumb.dragging { opacity: .4; }

/* Form panel */
.form-empty { color: var(--muted); font-size: 12px; padding: 8px 2px; }
.ff { display: flex; flex-direction: column; gap: 4px; margin-bottom: 12px; }
.ff > label.name { font-size: 12px; color: var(--muted); word-break: break-word; }
.ff input[type=text], .ff select { width: 100%; }
.ff .opt { display: flex; align-items: center; gap: 6px; font-size: 13px; }
.ff.focus-flash input, .ff.focus-flash select { outline: 2px solid var(--focus); }
.form-src { font-weight: 600; margin: 4px 0 8px; font-size: 12px; }

/* Empty state */
#empty { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; padding: 16px; }
.empty-card { text-align: center; max-width: 420px; background: var(--panel); padding: 36px 32px; border-radius: 16px; box-shadow: var(--shadow); }
.empty-card h1 { margin: 10px 0 6px; font-size: 22px; }
.empty-card p { margin: 8px 0 18px; }
.logo svg { width: 64px; height: 64px; }
#dropHint { position: fixed; inset: 0; background: color-mix(in srgb, var(--accent) 18%, transparent); border: 3px dashed var(--accent); display: none; align-items: center; justify-content: center; z-index: 50; pointer-events: none; font-size: 20px; font-weight: 600; text-align: center; color: var(--text); }
body.dragging-file #dropHint { display: flex; }

/* Toast */
#toast { position: fixed; left: 50%; bottom: 24px; transform: translateX(-50%) translateY(20px); background: #1f2328; color: #fff; padding: 10px 16px; border-radius: 9px; box-shadow: var(--shadow); opacity: 0; transition: .2s; pointer-events: none; z-index: 60; max-width: min(560px, calc(100vw - 32px)); }
#toast.show { opacity: 1; transform: translateX(-50%) translateY(0); }
#toast.error { background: #b42318; }

/* Dialogs */
dialog { border: 0; border-radius: 14px; padding: 0; background: var(--panel); color: var(--text); box-shadow: 0 20px 60px rgba(0,0,0,.35); max-width: calc(100vw - 32px); }
dialog::backdrop { background: rgba(10,12,16,.45); }
.dlg { padding: 20px 22px; display: flex; flex-direction: column; gap: 12px; min-width: min(600px, calc(100vw - 32px)); }
.dlg h2 { margin: 0; font-size: 17px; }
.dlg .row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.dlg input[type=text] { width: 100%; height: 36px; }
.small-tabs { padding: 0; }
#sigPad { width: 100%; height: auto; aspect-ratio: 560 / 200; background: #fff; border: 1px dashed var(--border); border-radius: 10px; touch-action: none; cursor: crosshair; }
.sig-type-preview { height: 110px; display: flex; align-items: center; justify-content: center; background: #fff; border-radius: 10px; border: 1px dashed var(--border); font: 48px "Segoe Script", "Brush Script MT", "Snell Roundhand", "Apple Chancery", cursive; color: #111827; overflow: hidden; white-space: nowrap; }
.sig-saved { display: flex; flex-wrap: wrap; gap: 10px; min-height: 120px; }
.sig-saved .item { position: relative; background: #fff; border: 2px solid var(--border); border-radius: 10px; padding: 8px; cursor: pointer; }
.sig-saved .item.sel { border-color: var(--focus); }
.sig-saved img { height: 70px; max-width: 220px; display: block; }
.sig-saved .del { position: absolute; top: -8px; right: -8px; width: 22px; height: 22px; border-radius: 50%; border: 0; background: var(--accent); color: #fff; cursor: pointer; line-height: 22px; padding: 0; }
.help table { border-collapse: collapse; }
.help td { padding: 4px 12px 4px 0; vertical-align: top; }
kbd { font: 11px ui-monospace, Menlo, Consolas, monospace; border: 1px solid var(--border); border-bottom-width: 2px; border-radius: 4px; padding: 1px 5px; background: var(--panel-2); }
code { font: 12px ui-monospace, Menlo, Consolas, monospace; }

@media (max-width: 1320px) {
  .toolbar .btn.label:not(.primary) { font-size: 0; gap: 0; padding: 0 7px; }
  .search-box input { width: 140px; }
}
@media (max-width: 900px) {
  .toolbar .btn.label, .subbar .btn.label { font-size: 0; gap: 0; padding: 0 7px; }
  .search-box input { width: 130px; }
  #sidebar { width: 160px; }
}

/* ---------- Markdown mode ---------- */
body.mode-md .pdf-only, body.mode-pdf .md-only, body:not(.mode-md) .md-only { display: none !important; }
.seg { display: inline-flex; border: 1px solid var(--border); border-radius: 8px; padding: 2px; background: var(--panel); }
.seg-btn { border: 0; background: none; padding: 4px 12px; border-radius: 6px; cursor: pointer; color: var(--muted); font-weight: 500; }
.seg-btn[aria-pressed="true"] { background: var(--accent-soft); color: var(--accent); }
#mdStats { margin-left: 10px; }
#mdWrap { position: absolute; inset: 0; display: grid; grid-template-columns: minmax(0, 1fr); --md-zoom: 1; }
#mdWrap.v-split { grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); }
#mdSource {
  display: none; width: 100%; height: 100%; resize: none; border: 0; outline: none; margin: 0;
  padding: 24px 28px; background: var(--panel); color: var(--text); tab-size: 4;
  font: calc(13.5px * var(--md-zoom)) / 1.6 ui-monospace, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
}
#mdWrap.v-split #mdSource { display: block; border-right: 1px solid var(--border); }
#mdWrap.v-source #mdSource { display: block; max-width: 980px; margin: 0 auto; border-left: 1px solid var(--border); border-right: 1px solid var(--border); }
#mdWrap.v-source #mdScroll { display: none; }
#mdScroll { overflow: auto; height: 100%; min-width: 0; padding: 24px 24px 48px; }
#outline { padding: 8px 6px; }
.ol-item { display: block; width: 100%; text-align: left; border: 0; background: none; cursor: pointer; padding: 5px 8px; border-radius: 6px; color: var(--text); font-size: 12.5px; line-height: 1.35; }
.ol-item:hover { background: var(--hover); }
.ol-item.active { background: var(--accent-soft); color: var(--accent); }
.ol-item.l2 { padding-left: 18px; } .ol-item.l3 { padding-left: 30px; color: var(--muted); } .ol-item.l4 { padding-left: 42px; color: var(--muted); }
mark.find { background: #fde68a; color: inherit; border-radius: 2px; }
mark.find.cur { background: #fb923c; }

.markdown-body {
  --md-code-bg: #f3f4f6; --md-border: #e5e7eb; --md-quote: #6b7280; --md-link: #2563eb;
  max-width: 880px; margin: 0 auto; padding: 44px 56px; background: var(--panel); border-radius: 12px; box-shadow: var(--shadow);
  font: calc(16px * var(--md-zoom)) / 1.65 system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  color: var(--text); word-wrap: break-word; overflow-wrap: anywhere;
}
@media (prefers-color-scheme: dark) { .markdown-body { --md-code-bg: #2a2e35; --md-border: #3a3f47; --md-quote: #a3aab4; --md-link: #7aa7ff; } }
.markdown-body > :first-child { margin-top: 0 !important; }
.markdown-body h1, .markdown-body h2, .markdown-body h3, .markdown-body h4, .markdown-body h5, .markdown-body h6 { margin: 1.6em 0 .6em; line-height: 1.25; font-weight: 650; scroll-margin-top: 16px; }
.markdown-body h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid var(--md-border); }
.markdown-body h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid var(--md-border); }
.markdown-body h3 { font-size: 1.25em; } .markdown-body h4 { font-size: 1.05em; } .markdown-body h5, .markdown-body h6 { font-size: .95em; color: var(--md-quote); }
.markdown-body p, .markdown-body ul, .markdown-body ol, .markdown-body blockquote, .markdown-body pre, .markdown-body table, .markdown-body details { margin: 0 0 1em; }
.markdown-body a { color: var(--md-link); text-decoration: none; }
.markdown-body a:hover { text-decoration: underline; }
.markdown-body ul, .markdown-body ol { padding-left: 2em; }
.markdown-body li + li { margin-top: .25em; }
.markdown-body li > p { margin: .4em 0; }
.markdown-body ul:has(> li > input[type=checkbox]) { list-style: none; padding-left: 1.2em; }
.markdown-body li > input[type=checkbox] { margin: 0 .5em 0 -1.2em; vertical-align: middle; }
.markdown-body blockquote { padding: .2em 1em; color: var(--md-quote); border-left: 4px solid var(--md-border); }
.markdown-body code { font: .875em/1.5 ui-monospace, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace; background: var(--md-code-bg); padding: .15em .4em; border-radius: 5px; }
.markdown-body pre { background: var(--md-code-bg); padding: 14px 16px; border-radius: 8px; overflow: auto; line-height: 1.5; }
.markdown-body pre code { background: none; padding: 0; font-size: .85em; white-space: pre; }
.markdown-body .table-wrap { overflow-x: auto; margin: 0 0 1em; }
.markdown-body table { border-collapse: collapse; margin: 0; }
.markdown-body th, .markdown-body td { border: 1px solid var(--md-border); padding: 6px 13px; }
.markdown-body th { background: var(--md-code-bg); font-weight: 600; }
.markdown-body tr:nth-child(2n) td { background: color-mix(in srgb, var(--md-code-bg) 45%, transparent); }
.markdown-body img { max-width: 100%; height: auto; }
.markdown-body hr { border: 0; height: 1px; background: var(--md-border); margin: 1.8em 0; }
.markdown-body kbd { font-size: .8em; }
.markdown-body .img-missing { display: inline-block; padding: 6px 10px; border: 1px dashed var(--md-border); border-radius: 6px; color: var(--muted); font-size: .85em; }
.markdown-body details.frontmatter { font-size: .85em; color: var(--muted); border: 1px solid var(--md-border); border-radius: 8px; padding: 6px 12px; }
.markdown-body details.frontmatter pre { margin: 8px 0 4px; }
/* code colors (highlight.js) */
.hljs-comment, .hljs-quote { color: #6a737d; font-style: italic; }
.hljs-keyword, .hljs-selector-tag, .hljs-literal, .hljs-type, .hljs-doctag { color: #cf222e; }
.hljs-string, .hljs-regexp, .hljs-addition, .hljs-attribute, .hljs-meta .hljs-string { color: #0a3069; }
.hljs-number, .hljs-symbol, .hljs-bullet, .hljs-variable, .hljs-template-variable { color: #0550ae; }
.hljs-title, .hljs-section, .hljs-title.function_, .hljs-name { color: #8250df; }
.hljs-built_in, .hljs-attr, .hljs-property, .hljs-selector-class, .hljs-selector-id { color: #953800; }
.hljs-deletion { color: #82071e; } .hljs-meta { color: #57606a; } .hljs-emphasis { font-style: italic; } .hljs-strong { font-weight: 700; }
@media (prefers-color-scheme: dark) {
  .hljs-comment, .hljs-quote { color: #8b949e; }
  .hljs-keyword, .hljs-selector-tag, .hljs-literal, .hljs-type, .hljs-doctag { color: #ff7b72; }
  .hljs-string, .hljs-regexp, .hljs-addition, .hljs-attribute, .hljs-meta .hljs-string { color: #a5d6ff; }
  .hljs-number, .hljs-symbol, .hljs-bullet, .hljs-variable, .hljs-template-variable { color: #79c0ff; }
  .hljs-title, .hljs-section, .hljs-title.function_, .hljs-name { color: #d2a8ff; }
  .hljs-built_in, .hljs-attr, .hljs-property, .hljs-selector-class, .hljs-selector-id { color: #ffa657; }
  .hljs-meta { color: #8b949e; }
}
@media (max-width: 900px) { .markdown-body { padding: 24px 22px; } #mdScroll { padding: 12px; } }

/* Printing a Markdown document: print only the formatted text, in light colors */
@media print {
  :root { --bg: #fff; --panel: #fff; --text: #111; --muted: #555; --border: #ddd; }
  .markdown-body { --md-code-bg: #f3f4f6; --md-border: #ddd; --md-quote: #555; --md-link: #1d4ed8; }
  html, body { height: auto; overflow: visible; background: #fff; }
  body.mode-md #app { display: block; height: auto; }
  body.mode-md .toolbar, body.mode-md .subbar, body.mode-md #sidebar, body.mode-md #mdSource, #toast, #dropHint, #empty { display: none !important; }
  body.mode-md .main, body.mode-md #viewer, body.mode-md #mdWrap, body.mode-md #mdScroll { display: block !important; position: static; overflow: visible; height: auto; padding: 0; background: #fff; }
  body.mode-md #mdWrap.v-source #mdScroll { display: block !important; }
  .markdown-body { max-width: none; padding: 0; box-shadow: none; border-radius: 0; font-size: 11pt; }
  .markdown-body pre, .markdown-body pre code { white-space: pre-wrap; }
  .markdown-body h1, .markdown-body h2, .markdown-body h3, .markdown-body h4 { break-after: avoid; }
  .markdown-body pre, .markdown-body table, .markdown-body img, .markdown-body blockquote { break-inside: avoid; }
  .hljs-comment, .hljs-quote { color: #6a737d; } .hljs-keyword, .hljs-literal, .hljs-type { color: #cf222e; } .hljs-string { color: #0a3069; } .hljs-number { color: #0550ae; } .hljs-title, .hljs-name { color: #8250df; } .hljs-built_in, .hljs-attr { color: #953800; }
}
```

### 9.5 `src/app.js`: the app logic
Everything sits inside one function, `(() => { … })()`, so nothing leaks into the global scope. The sections, in file order:

| Section | What it does |
|---|---|
| setup | Starts the PDF.js worker from the embedded code (Blob URL + `workerPort`) |
| helpers | `$`, `el()` (create elements), color conversion, `localStorage` wrapper that never throws |
| icons | SVG path data for every toolbar icon |
| fonts | The 6 standard PDF fonts. pdf-lib measures text width and checks which characters each font supports; others become `?` |
| state | `S` holds everything: open files, page list, edits, tool, zoom, undo stack |
| geometry | Conversion between **screen pixels** and **PDF points** (PDF origin is bottom-left, y goes up). Bounding boxes, hit testing |
| drawing annotations | Draws one edit on any canvas (main overlay or thumbnail) |
| loading | Opens a PDF with PDF.js (asks for a password if needed), reads form fields, builds the page list |
| page views | One `<div class="page">` per page. Pages are drawn **only when near the screen** (IntersectionObserver) and freed when far away, so a 300-page PDF still opens instantly |
| zoom & scrolling | Fit width / fit page / percentages, Ctrl+wheel zoom, keeps your place when zooming, tracks the current page |
| thumbnails | Small page previews (cached), drag and drop to reorder |
| undo / redo | Before every change, a copy of the page list is saved (`structuredClone`) |
| tools / props bar | Tool switching; color, font, size and line width for the tool or the selected edit |
| text editor | A `<textarea>` placed over the page for typing; turned into a text edit when you press Esc or click away |
| pointer interaction | Mouse/touch: draw, drag boxes, select, move, resize, double-click to edit |
| images & signatures | Image import (re-encodes photos so phone rotation is correct), signature pad (draw or type), saved signatures |
| page operations | Rotate, move, delete, insert blank, page ranges like `1-3, 5` |
| forms | The Form panel. Values go into PDF.js's "annotation storage" so they show on the page right away |
| search | Finds text using PDF.js text content and draws highlight boxes |
| export (save) | Builds the output PDF with pdf-lib (details below) |
| Markdown | Open, render (marked → DOMPurify → highlight.js), outline, Preview/Split/Source, find, print |
| UI wiring | Buttons, keyboard shortcuts, drag and drop of files |

**How edits are stored.** Each page has an `annots` list. Every edit is plain data in PDF coordinates, which is why undo is just "restore an older copy of this list":
```js
{ type: 'text', x: 72, y: 700, angle: 0, text: 'Hello', size: 14, color: '#111827', font: 'Helvetica' }
{ type: 'ink', points: [[100, 500], [104, 503]], color: '#d6402b', width: 2 }
{ type: 'highlight' | 'rect' | 'whiteout', r: { x0, y0, x1, y1 }, color: '#fde047' }
{ type: 'image', img: '<image id>', r: { x0, y0, x1, y1 }, angle: 0 }
```
`angle` stores the page rotation at the moment you added the edit, so text stays upright on rotated pages.

**How saving works (`exportPdf`).**
1. Each source PDF is loaded into pdf-lib, and the Form panel values are written in (`applyFormValues`).
2. **Keep or rebuild the original:**
   - If the first PDF has form fields, or you only edited one PDF without removing pages, the original document is reused. This keeps fillable fields, bookmarks and metadata.
   - Otherwise a fresh PDF is made and only the pages you kept are copied in, so deleted pages really shrink the file.
3. Pages are put in your order with your rotation, and blank pages are added.
4. Your edits are drawn into each page: highlights first (using the "multiply" blend), then everything else.
5. **Protected PDFs** can't be rewritten by pdf-lib. After asking you, their pages are saved as high-resolution images with your edits on top.

**File: `src/app.js`**

```js
'use strict';
/* PDF Studio — offline PDF reader & editor.
   Viewing: PDF.js. Writing: pdf-lib. Everything runs locally in the browser. */
(() => {
const {
  PDFDocument, PDFPage, PDFName, StandardFonts, rgb, degrees, BlendMode,
  pushGraphicsState, popGraphicsState, setLineWidth, setStrokingColor,
  moveTo, lineTo, stroke, setLineCap, setLineJoin, LineCapStyle, LineJoinStyle,
} = PDFLib;

// PDF.js worker is embedded in the page so the app works offline from a single file.
try {
  const workerCode = document.getElementById('pdfjs-worker-src').textContent;
  const workerUrl = URL.createObjectURL(new Blob([workerCode], { type: 'text/javascript' }));
  pdfjsLib.GlobalWorkerOptions.workerSrc = workerUrl;
  // Hand PDF.js a ready worker: its own origin check fails for file:// pages.
  pdfjsLib.GlobalWorkerOptions.workerPort = new Worker(workerUrl);
} catch (e) { console.warn('Worker setup failed', e); }

/* ---------- helpers ---------- */
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const CSS_UNITS = 96 / 72;
const uid = () => Math.random().toString(36).slice(2, 10);
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
const isMac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
const store = {
  get(k, d) { try { const v = localStorage.getItem('pdfstudio.' + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem('pdfstudio.' + k, JSON.stringify(v)); } catch {} },
};
function el(tag, attrs = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') e.className = v;
    else if (k === 'style') Object.assign(e.style, v);
    else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
    else if (v !== false && v != null) e.setAttribute(k, v === true ? '' : v);
  }
  for (const c of kids) if (c != null) e.append(c);
  return e;
}
function hexToRgb(hex) {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex || '') ;
  const n = m ? parseInt(m[1], 16) : 0;
  return rgb(((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255);
}
function b64ToBytes(dataUrl) {
  const b = atob(dataUrl.split(',')[1]);
  const u = new Uint8Array(b.length);
  for (let i = 0; i < b.length; i++) u[i] = b.charCodeAt(i);
  return u;
}
const loadImg = (src) => new Promise((res, rej) => { const i = new Image(); i.onload = () => res(i); i.onerror = () => rej(new Error('Could not read that image.')); i.src = src; });
const canvasToBlob = (c, type, q) => new Promise((res) => c.toBlob(res, type, q));

/* ---------- icons ---------- */
const ICONS = {
  sidebar: 'M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z|M9 3v18',
  open: 'M6 14l1.45-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.55 6a2 2 0 0 1-1.94 1.5H4a2 2 0 0 1-2-2V5c0-1.1.9-2 2-2h3.93a2 2 0 0 1 1.66.9l.82 1.2a2 2 0 0 0 1.66.9H18a2 2 0 0 1 2 2v2',
  filePlus: 'M14.5 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7.5L14.5 2z|M14 2v6h6|M12 18v-6|M9 15h6',
  fileBlank: 'M14.5 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7.5L14.5 2z|M14 2v6h6|M12 18v-6|M9 15h6',
  save: 'M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z|M17 21v-8H7v8|M7 3v5h8',
  undo: 'M3 7v6h6|M21 17a9 9 0 0 0-9-9 9 9 0 0 0-6 2.3L3 13',
  redo: 'M21 7v6h-6|M3 17a9 9 0 0 1 9-9 9 9 0 0 1 6 2.3l3 2.7',
  cursorText: 'M17 22h-1a4 4 0 0 1-4-4V6a4 4 0 0 1 4-4h1|M7 22h1a4 4 0 0 0 4-4v-1|M7 2h1a4 4 0 0 1 4 4v1',
  pointer: 'M4 4l7.07 16.97 2.51-7.39 7.39-2.51L4 4z|M13.5 13.5l6 6',
  type: 'M4 7V4h16v3|M9 20h6|M12 4v16',
  pen: 'M12 20h9|M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z',
  highlighter: 'M9 11l-6 6v3h9l3-3|M22 12l-4.6 4.6a2 2 0 0 1-2.8 0l-5.2-5.2a2 2 0 0 1 0-2.8L14 4',
  square: 'M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z',
  eraser: 'M7 21l-4.3-4.3c-1-1-1-2.5 0-3.4l9.6-9.6c1-1 2.5-1 3.4 0l5.6 5.6c1 1 1 2.5 0 3.4L13 21|M22 21H7|M5 11l9 9',
  image: 'M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z|M21 15l-5-5L5 21|M9 7a2 2 0 1 1 0 4 2 2 0 0 1 0-4z',
  signature: 'M3 17c3-3 4-10 6-10s1 7 3 7 2-3 4-3 1 3 3 3 2-1 2-1|M3 21h18',
  zoomIn: 'M11 4a7 7 0 1 1 0 14 7 7 0 0 1 0-14z|M21 21l-4.35-4.35|M11 8v6|M8 11h6',
  zoomOut: 'M11 4a7 7 0 1 1 0 14 7 7 0 0 1 0-14z|M21 21l-4.35-4.35|M8 11h6',
  search: 'M11 4a7 7 0 1 1 0 14 7 7 0 0 1 0-14z|M21 21l-4.35-4.35',
  chevUp: 'M18 15l-6-6-6 6',
  chevDown: 'M6 9l6 6 6-6',
  help: 'M12 2a10 10 0 1 1 0 20 10 10 0 0 1 0-20z|M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3|M12 17h.01',
  rotL: 'M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8|M3 3v5h5',
  rotR: 'M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8|M21 3v5h-5',
  arrowUp: 'M12 19V5|M5 12l7-7 7 7',
  arrowDown: 'M12 5v14|M19 12l-7 7-7-7',
  trash: 'M3 6h18|M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6|M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2',
  scissors: 'M6 3a3 3 0 1 1 0 6 3 3 0 0 1 0-6z|M6 15a3 3 0 1 1 0 6 3 3 0 0 1 0-6z|M20 4L8.12 15.88|M14.47 14.48L20 20|M8.12 8.12L12 12',
  printer: 'M6 9V2h12v7|M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2|M6 14h12v8H6z',
};
function svgIcon(name) {
  if (name === 'logo') {
    return '<svg viewBox="0 0 64 64" aria-hidden="true"><rect x="4" y="4" width="56" height="56" rx="14" fill="#d6402b"/><path d="M22 14h14l10 10v24a3 3 0 0 1-3 3H22a3 3 0 0 1-3-3V17a3 3 0 0 1 3-3z" fill="#fff"/><path d="M36 14v10h10" fill="#f6c3ba"/><path d="M25 41c4-4 5-12 8-12s1 9 4 9 3-3 5-3" fill="none" stroke="#d6402b" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  }
  const d = (ICONS[name] || '').split('|').map((p) => `<path d="${p}"/>`).join('');
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${d}</svg>`;
}
for (const n of $$('[data-icon]')) n.insertAdjacentHTML('afterbegin', svgIcon(n.dataset.icon));

/* ---------- fonts ---------- */
const FONTS = {
  'Helvetica': { pdf: 'Helvetica', css: 'Helvetica, Arial, "Liberation Sans", sans-serif', weight: 400 },
  'Helvetica-Bold': { pdf: 'HelveticaBold', css: 'Helvetica, Arial, "Liberation Sans", sans-serif', weight: 700 },
  'Times': { pdf: 'TimesRoman', css: '"Times New Roman", Times, "Liberation Serif", serif', weight: 400 },
  'Times-Bold': { pdf: 'TimesRomanBold', css: '"Times New Roman", Times, "Liberation Serif", serif', weight: 700 },
  'Courier': { pdf: 'Courier', css: '"Courier New", Courier, "Liberation Mono", monospace', weight: 400 },
  'Courier-Bold': { pdf: 'CourierBold', css: '"Courier New", Courier, "Liberation Mono", monospace', weight: 700 },
};
const MF = {}; // measuring fonts (pdf-lib), used for exact text widths and character support
const fontsReady = (async () => {
  const d = await PDFDocument.create();
  for (const [k, f] of Object.entries(FONTS)) {
    MF[k] = await d.embedFont(StandardFonts[f.pdf]);
    MF[k].charset = new Set(MF[k].getCharacterSet());
  }
})();
let warnedChars = false;
function sanitize(fontName, s) {
  const f = MF[fontName];
  s = s.replace(/\r/g, '').replace(/\t/g, '    ');
  if (!f) return s;
  let bad = false;
  const out = [...s].map((ch) => {
    if (ch === '\n') return ch;
    if (f.charset.has(ch.codePointAt(0))) return ch;
    bad = true; return '?';
  }).join('');
  if (bad && !warnedChars) { warnedChars = true; toast('Some characters aren’t supported by the built-in PDF fonts and were replaced with “?”.', 'error', 5000); }
  return out;
}
const measureCanvas = document.createElement('canvas').getContext('2d');
function textWidth(fontName, size, line) {
  const f = MF[fontName];
  if (f) { try { return f.widthOfTextAtSize(line, size); } catch {} }
  const ff = FONTS[fontName];
  measureCanvas.font = `${ff.weight} ${size}px ${ff.css}`;
  return measureCanvas.measureText(line).width;
}

/* ---------- state ---------- */
const DEFAULT_DEFS = {
  text: { color: '#111827', size: 14, font: 'Helvetica' },
  ink: { color: '#d6402b', width: 2 },
  rect: { color: '#d6402b', width: 2 },
  highlight: { color: '#fde047' },
  whiteout: { color: '#ffffff' },
};
const S = {
  sources: new Map(),   // id -> { id, name, bytes, doc, fields, formChanged, formVer, encrypted }
  pages: [],            // { id, src, idx, view:[x0,y0,x1,y1], rot, blank, annots:[] }
  images: new Map(),    // id -> { bytes, type:'png'|'jpg', el }
  name: 'document.pdf',
  zoom: 1, zoomMode: 'fitw',
  tool: 'read',
  sel: null,            // { pid, aid }
  editing: null,        // { pid, a, isNew, ta }
  temp: null,           // { pid, a } annotation being drawn
  undo: [], redo: [],
  dirty: false,
  current: 0,
  defs: Object.assign(structuredClone(DEFAULT_DEFS), store.get('defs', {})),
  search: { q: '', hits: [], cur: -1, token: 0 },
};
const views = new Map();   // page id -> view
const thumbs = new Map();  // page id -> thumb
const pageById = (id) => S.pages.find((p) => p.id === id);
const findAnnot = (p, id) => p && p.annots.find((a) => a.id === id);

/* ---------- toast / busy ---------- */
let toastTimer;
function toast(msg, kind = '', ms = 2600) {
  const t = $('#toast');
  t.textContent = msg; t.className = 'show ' + kind;
  clearTimeout(toastTimer);
  if (ms) toastTimer = setTimeout(() => { t.className = ''; }, ms);
}
function hideToast() { $('#toast').className = ''; }
window.addEventListener('error', (e) => toast('Something went wrong: ' + (e.message || e), 'error', 5000));
window.addEventListener('unhandledrejection', (e) => {
  if (e.reason && e.reason.name === 'RenderingCancelledException') return;
  if (e.reason && e.reason.name === 'AbortError') return;
  console.error(e.reason);
  toast('Something went wrong: ' + ((e.reason && e.reason.message) || e.reason), 'error', 5000);
});

/* ---------- geometry ---------- */
let PageViewport = pdfjsLib.PageViewport; // not exported by every PDF.js build; captured on first load
function vpFor(p, scale = S.zoom * CSS_UNITS) {
  return new PageViewport({ viewBox: p.view, scale, rotation: p.rot, offsetX: 0, offsetY: 0 });
}
function dispSize(p) { // displayed size in points (rotation-aware)
  const w = p.view[2] - p.view[0], h = p.view[3] - p.view[1];
  return p.rot % 180 ? [h, w] : [w, h];
}
function rectFromView(vp, x0, y0, x1, y1) {
  const [a, b] = vp.convertToPdfPoint(x0, y0), [c, d] = vp.convertToPdfPoint(x1, y1);
  return { x0: Math.min(a, c), y0: Math.min(b, d), x1: Math.max(a, c), y1: Math.max(b, d) };
}
function viewBoxOf(vp, pts, pad = 0) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const [x, y] of pts) {
    const [vx, vy] = vp.convertToViewportPoint(x, y);
    x0 = Math.min(x0, vx); y0 = Math.min(y0, vy); x1 = Math.max(x1, vx); y1 = Math.max(y1, vy);
  }
  return { x: x0 - pad, y: y0 - pad, w: x1 - x0 + 2 * pad, h: y1 - y0 + 2 * pad };
}
function imgPlace(a) { // image rect + angle -> pdf-lib anchor/size
  const r = a.r, W = r.x1 - r.x0, H = r.y1 - r.y0;
  switch (((a.angle % 360) + 360) % 360) {
    case 90: return { x: r.x1, y: r.y0, w: H, h: W };
    case 180: return { x: r.x1, y: r.y1, w: W, h: H };
    case 270: return { x: r.x0, y: r.y1, w: H, h: W };
    default: return { x: r.x0, y: r.y0, w: W, h: H };
  }
}
function textMetrics(a) {
  const lines = a.text.split('\n');
  let w = 0;
  for (const l of lines) w = Math.max(w, textWidth(a.font, a.size, l));
  return { lines, w: Math.max(w, a.size * 0.4), n: lines.length };
}
function annotPdfPoints(a) {
  switch (a.type) {
    case 'ink': return a.points;
    case 'text': {
      const { w, n } = textMetrics(a);
      const asc = a.size * 0.8, desc = a.size * 0.25 + (n - 1) * a.size * 1.2;
      const rad = a.angle * Math.PI / 180, c = Math.cos(rad), s = Math.sin(rad);
      return [[0, asc], [w, asc], [w, -desc], [0, -desc]].map(([u, v]) => [a.x + u * c - v * s, a.y + u * s + v * c]);
    }
    default: return [[a.r.x0, a.r.y0], [a.r.x1, a.r.y1]];
  }
}
function bboxView(vp, a) {
  const pad = a.type === 'ink' ? a.width * vp.scale / 2 + 2 : (a.type === 'rect' ? a.width * vp.scale / 2 : 0);
  return viewBoxOf(vp, annotPdfPoints(a), pad);
}
const resizable = (a) => ['rect', 'highlight', 'whiteout', 'image'].includes(a.type);
function distToSeg(px, py, ax, ay, bx, by) {
  const dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy;
  let t = l2 ? ((px - ax) * dx + (py - ay) * dy) / l2 : 0;
  t = clamp(t, 0, 1);
  return Math.hypot(px - (ax + t * dx), py - (ay + t * dy));
}
function hitTest(p, vp, pt) {
  for (let i = p.annots.length - 1; i >= 0; i--) {
    const a = p.annots[i];
    if (a.type === 'ink') {
      const tol = Math.max(6, a.width * vp.scale / 2 + 4);
      const vpts = a.points.map(([x, y]) => vp.convertToViewportPoint(x, y));
      if (vpts.length === 1 && Math.hypot(pt.x - vpts[0][0], pt.y - vpts[0][1]) < tol) return a;
      for (let j = 1; j < vpts.length; j++) {
        if (distToSeg(pt.x, pt.y, vpts[j - 1][0], vpts[j - 1][1], vpts[j][0], vpts[j][1]) < tol) return a;
      }
    } else {
      const b = bboxView(vp, a);
      if (pt.x >= b.x - 3 && pt.x <= b.x + b.w + 3 && pt.y >= b.y - 3 && pt.y <= b.y + b.h + 3) return a;
    }
  }
  return null;
}

/* ---------- drawing annotations on a canvas ---------- */
function drawAnnot(ctx, a, T, opts = {}) {
  ctx.save();
  ctx.setTransform(T[0], T[1], T[2], T[3], T[4], T[5]);
  switch (a.type) {
    case 'ink': {
      ctx.strokeStyle = a.color; ctx.lineWidth = a.width; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
      ctx.beginPath();
      ctx.moveTo(a.points[0][0], a.points[0][1]);
      if (a.points.length === 1) ctx.lineTo(a.points[0][0] + 0.01, a.points[0][1]);
      for (let i = 1; i < a.points.length; i++) ctx.lineTo(a.points[i][0], a.points[i][1]);
      ctx.stroke();
      break;
    }
    case 'rect':
      ctx.strokeStyle = a.color; ctx.lineWidth = a.width;
      ctx.strokeRect(a.r.x0, a.r.y0, a.r.x1 - a.r.x0, a.r.y1 - a.r.y0);
      break;
    case 'highlight':
      if (opts.multiply) ctx.globalCompositeOperation = 'multiply';
      ctx.fillStyle = a.color;
      ctx.fillRect(a.r.x0, a.r.y0, a.r.x1 - a.r.x0, a.r.y1 - a.r.y0);
      break;
    case 'whiteout':
      ctx.fillStyle = a.color;
      ctx.fillRect(a.r.x0, a.r.y0, a.r.x1 - a.r.x0, a.r.y1 - a.r.y0);
      break;
    case 'image': {
      const im = S.images.get(a.img);
      if (!im) break;
      const pl = imgPlace(a);
      ctx.translate(pl.x, pl.y); ctx.rotate(a.angle * Math.PI / 180); ctx.scale(1, -1);
      ctx.drawImage(im.el, 0, -pl.h, pl.w, pl.h);
      break;
    }
    case 'text': {
      const f = FONTS[a.font];
      ctx.translate(a.x, a.y); ctx.rotate(a.angle * Math.PI / 180); ctx.scale(1, -1);
      ctx.font = `${f.weight} ${a.size}px ${f.css}`;
      ctx.fillStyle = a.color; ctx.textBaseline = 'alphabetic';
      a.text.split('\n').forEach((ln, i) => ctx.fillText(ln, 0, i * a.size * 1.2));
      break;
    }
  }
  ctx.restore();
}

/* ---------- loading ---------- */
async function loadSource(bytes, name) {
  const task = pdfjsLib.getDocument({ data: bytes.slice(), isEvalSupported: false, enableXfa: false, fontExtraProperties: false });
  task.onPassword = (update, reason) => {
    const pw = prompt(reason === pdfjsLib.PasswordResponses.INCORRECT_PASSWORD
      ? 'Incorrect password. Try again:' : `“${name}” is password-protected. Enter the password:`);
    if (pw === null) task.destroy(); else update(pw);
  };
  const doc = await task.promise;
  if (!PageViewport) PageViewport = (await doc.getPage(1)).getViewport({ scale: 1 }).constructor;
  const src = { id: uid(), name, bytes, doc, fields: null, formChanged: false, formVer: 0, encrypted: false };
  try { src.fields = await doc.getFieldObjects(); } catch { src.fields = null; }
  const pages = [];
  for (let i = 0; i < doc.numPages; i++) {
    const pg = await doc.getPage(i + 1);
    pages.push({ id: uid(), src: src.id, idx: i, view: pg.view.slice(), rot: pg.rotate, blank: false, annots: [] });
  }
  S.sources.set(src.id, src);
  return { src, pages };
}
async function readFile(file) { return new Uint8Array(await file.arrayBuffer()); }

async function openFiles(files, mode) {
  files = [...files].filter((f) => /\.pdf$/i.test(f.name) || f.type === 'application/pdf');
  if (!files.length) { toast('Please choose a PDF file.', 'error'); return; }
  if (mode === 'replace' && S.dirty && !confirm('You have unsaved changes. Discard them and open another file?')) return;
  toast('Opening…', '', 0);
  try {
    const loaded = [];
    for (const f of files) loaded.push(await loadSource(await readFile(f), f.name));
    if (mode === 'replace' || !S.pages.length) {
      closeEditor(true);
      leaveMarkdown();
      setMode('pdf');
      for (const s of S.sources.values()) if (!loaded.some((l) => l.src === s)) { try { s.doc.destroy(); } catch {} S.sources.delete(s.id); }
      S.pages = loaded.flatMap((l) => l.pages);
      S.name = files[0].name;
      S.undo = []; S.redo = []; S.sel = null; S.current = 0;
      clearSearch();
      setDirty(files.length > 1);
      S.zoomMode = 'fitw';
      buildPages();
      applyZoom(true);
      $('#viewer').scrollTop = 0;
      setTool('read');
      hideToast();
    } else {
      pushUndo();
      const at = S.pages.length;
      S.pages.push(...loaded.flatMap((l) => l.pages));
      buildPages();
      scrollToIndex(at);
      toast(`Added ${loaded.reduce((n, l) => n + l.pages.length, 0)} page(s) from ${files.map((f) => f.name).join(', ')}`);
    }
    buildFormPanel();
    updateUI();
  } catch (e) {
    console.error(e);
    toast(e && e.name === 'PasswordException' ? 'Opening cancelled.' : 'Could not open that file. Is it a valid PDF?', 'error', 5000);
  }
}

/* ---------- page views ---------- */
const viewer = $('#viewer'), pagesEl = $('#pages');
const io = new IntersectionObserver((entries) => {
  for (const en of entries) {
    const v = views.get(en.target.dataset.id);
    if (!v) continue;
    v.visible = en.isIntersecting;
    if (v.visible) { renderPage(v); drawOverlay(v.p); } else freePage(v);
  }
}, { root: viewer, rootMargin: '100% 0px' });

function createView(p) {
  const v = { p, key: null, task: null, visible: false };
  v.el = el('div', { class: 'page', 'data-id': p.id });
  v.canvas = el('canvas', { class: 'pdf' });
  v.hl = el('canvas', { class: 'hl' });
  v.tl = el('div', { class: 'textLayer' });
  v.ov = el('canvas', { class: 'ov' });
  v.num = el('div', { class: 'pnum' });
  v.el.append(v.canvas, v.hl, v.tl, v.ov, v.num);
  return v;
}
function sizeView(v) {
  const vp = vpFor(v.p);
  v.el.style.width = Math.floor(vp.width) + 'px';
  v.el.style.height = Math.floor(vp.height) + 'px';
}
function buildPages() {
  const old = new Map(views);
  views.clear();
  const frag = document.createDocumentFragment();
  S.pages.forEach((p, i) => {
    let v = old.get(p.id);
    if (v) old.delete(p.id); else { v = createView(p); io.observe(v.el); }
    v.p = p;
    v.num.textContent = String(i + 1);
    sizeView(v);
    views.set(p.id, v);
    frag.append(v.el);
  });
  for (const v of old.values()) { io.unobserve(v.el); freePage(v); v.el.remove(); }
  pagesEl.append(frag);
  for (const v of views.values()) if (v.visible) { renderPage(v); drawOverlay(v.p); }
  if (S.sel && !findAnnot(pageById(S.sel.pid), S.sel.aid)) S.sel = null;
  S.current = clamp(S.current, 0, Math.max(0, S.pages.length - 1));
  buildThumbs();
  updateUI();
}
function freePage(v) {
  if (v.task) { try { v.task.cancel(); } catch {} v.task = null; }
  v.key = null;
  if (v.canvas.width) { v.canvas.width = 0; v.canvas.height = 0; }
  if (v.hl.width) { v.hl.width = 0; v.hl.height = 0; }
  if (v.ov.width) { v.ov.width = 0; v.ov.height = 0; }
  v.tl.replaceChildren();
}
const textCache = new Map();
function getText(p) {
  const k = p.src + '|' + p.idx;
  if (!textCache.has(k)) {
    textCache.set(k, S.sources.get(p.src).doc.getPage(p.idx + 1).then((pg) => pg.getTextContent()));
  }
  return textCache.get(k);
}
function effDpr(vp) {
  const max = 16e6; // keep canvases under ~16 megapixels
  const d = window.devicePixelRatio || 1;
  return Math.min(d, Math.sqrt(max / Math.max(1, vp.width * vp.height)));
}
async function renderPage(v) {
  const p = v.p;
  const src = p.blank ? null : S.sources.get(p.src);
  const scale = S.zoom * CSS_UNITS;
  const key = [scale, p.rot, p.src, p.idx, src ? src.formVer : 0, window.devicePixelRatio].join('|');
  if (v.key === key) return;
  v.key = key;
  if (v.task) { try { v.task.cancel(); } catch {} v.task = null; }
  const vp = vpFor(p, scale);
  const dpr = effDpr(vp);
  const nc = el('canvas', { class: 'pdf' });
  nc.width = Math.floor(vp.width * dpr); nc.height = Math.floor(vp.height * dpr);
  nc.style.width = Math.floor(vp.width) + 'px'; nc.style.height = Math.floor(vp.height) + 'px';
  const ctx = nc.getContext('2d');
  ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, nc.width, nc.height);
  if (p.blank) { v.el.replaceChild(nc, v.canvas); v.canvas = nc; v.tl.replaceChildren(); return; }
  try {
    const page = await src.doc.getPage(p.idx + 1);
    if (v.key !== key) return;
    v.task = page.render({
      canvasContext: ctx, viewport: vp,
      transform: dpr !== 1 ? [dpr, 0, 0, dpr, 0, 0] : null,
      annotationMode: pdfjsLib.AnnotationMode.ENABLE_STORAGE,
    });
    await v.task.promise;
    v.task = null;
    if (v.key !== key) return;
    v.el.replaceChild(nc, v.canvas); v.canvas = nc;
    // selectable text layer
    const tc = await getText(p);
    if (v.key !== key) return;
    const tl = el('div', { class: 'textLayer' });
    tl.style.setProperty('--scale-factor', String(scale));
    v.el.replaceChild(tl, v.tl); v.tl = tl;
    pdfjsLib.renderTextLayer({ textContentSource: tc, container: tl, viewport: vp, textDivs: [] });
  } catch (e) {
    if (e && e.name === 'RenderingCancelledException') return;
    v.key = null;
    console.error(e);
  }
}
function drawOverlay(p) {
  if (!p) return;
  const v = views.get(p.id);
  if (!v || !v.visible) return;
  const vp = vpFor(p);
  const dpr = effDpr(vp);
  const W = Math.floor(vp.width * dpr), H = Math.floor(vp.height * dpr);
  for (const c of [v.ov, v.hl]) {
    if (c.width !== W || c.height !== H) { c.width = W; c.height = H; }
    c.style.width = Math.floor(vp.width) + 'px'; c.style.height = Math.floor(vp.height) + 'px';
  }
  const T = vp.transform.map((x) => x * dpr);
  const hctx = v.hl.getContext('2d'), ctx = v.ov.getContext('2d');
  hctx.setTransform(1, 0, 0, 1, 0, 0); hctx.clearRect(0, 0, W, H);
  ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.clearRect(0, 0, W, H);
  // search hits
  S.search.hits.forEach((h, i) => {
    if (h.pid !== p.id) return;
    hctx.save(); hctx.setTransform(...T);
    hctx.fillStyle = i === S.search.cur ? '#fb923c' : '#fde68a';
    for (const q of h.quads) {
      hctx.beginPath(); hctx.moveTo(q[0][0], q[0][1]);
      for (let k = 1; k < 4; k++) hctx.lineTo(q[k][0], q[k][1]);
      hctx.closePath(); hctx.fill();
    }
    hctx.restore();
  });
  const list = p.annots.slice();
  if (S.temp && S.temp.pid === p.id) list.push(S.temp.a);
  for (const a of list) {
    if (S.editing && S.editing.a === a) continue;
    if (a.type === 'highlight') drawAnnot(hctx, a, T);
    else drawAnnot(ctx, a, T);
  }
  // selection
  if (S.sel && S.sel.pid === p.id) {
    const a = findAnnot(p, S.sel.aid);
    if (a) {
      const b = bboxView(vp, a);
      ctx.save(); ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.strokeStyle = '#2563eb'; ctx.lineWidth = 1.5; ctx.setLineDash([5, 3]);
      ctx.strokeRect(b.x - 3, b.y - 3, b.w + 6, b.h + 6);
      if (resizable(a)) {
        ctx.setLineDash([]); ctx.fillStyle = '#fff';
        ctx.fillRect(b.x + b.w - 2, b.y + b.h - 2, 10, 10);
        ctx.strokeRect(b.x + b.w - 2, b.y + b.h - 2, 10, 10);
      }
      ctx.restore();
    }
  }
}
function redrawAll() { for (const p of S.pages) drawOverlay(p); }

/* ---------- zoom & scrolling ---------- */
const ZOOMS = [0.25, 0.33, 0.5, 0.67, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5];
function fitZoom(mode) {
  if (!S.pages.length) return 1;
  const availW = viewer.clientWidth - 48 - 4;
  let maxW = 0;
  for (const p of S.pages) maxW = Math.max(maxW, dispSize(p)[0]);
  const zw = availW / (maxW * CSS_UNITS);
  if (mode === 'fitw') return clamp(zw, 0.25, 5);
  const [, h] = dispSize(S.pages[S.current] || S.pages[0]);
  const zh = (viewer.clientHeight - 40) / (h * CSS_UNITS);
  return clamp(Math.min(zw, zh), 0.25, 5);
}
function applyZoom(keepTop) {
  const v0 = views.get((S.pages[S.current] || {}).id);
  let frac = 0;
  if (v0 && !keepTop) frac = (viewer.scrollTop - v0.el.offsetTop) / Math.max(1, v0.el.offsetHeight);
  const fx = viewer.scrollWidth > viewer.clientWidth ? (viewer.scrollLeft + viewer.clientWidth / 2) / viewer.scrollWidth : 0.5;
  if (S.zoomMode === 'fitw' || S.zoomMode === 'fitp') S.zoom = fitZoom(S.zoomMode);
  for (const v of views.values()) sizeView(v);
  if (v0 && !keepTop) viewer.scrollTop = v0.el.offsetTop + frac * v0.el.offsetHeight;
  viewer.scrollLeft = fx * viewer.scrollWidth - viewer.clientWidth / 2;
  if (S.editing) closeEditor(false);
  for (const v of views.values()) if (v.visible) { renderPage(v); drawOverlay(v.p); }
  updateZoomUI();
}
function setZoom(z, mode = 'custom') {
  if (S.mode === 'md') { S.mdZoom = clamp(z, 0.5, 3); applyMdZoom(); return; }
  S.zoomMode = mode;
  S.zoom = clamp(z, 0.25, 5);
  applyZoom();
}
function zoomStep(dir) {
  const z = S.mode === 'md' ? S.mdZoom : S.zoom;
  const next = dir > 0 ? ZOOMS.find((x) => x > z + 0.001) : [...ZOOMS].reverse().find((x) => x < z - 0.001);
  if (next) setZoom(next);
}
function updateZoomUI() {
  const sel = $('#zoomSel');
  if (S.mode === 'md') {
    const opt = [...sel.options].find((o) => Math.abs(parseFloat(o.value) - S.mdZoom) < 0.001);
    if (opt) sel.value = opt.value;
    else { const c = sel.querySelector('[value=custom]'); c.textContent = Math.round(S.mdZoom * 100) + '%'; sel.value = 'custom'; }
    return;
  }
  if (S.zoomMode === 'fitw' || S.zoomMode === 'fitp') { sel.value = S.zoomMode; return; }
  const opt = [...sel.options].find((o) => Math.abs(parseFloat(o.value) - S.zoom) < 0.001);
  if (opt) sel.value = opt.value;
  else { const c = sel.querySelector('[value=custom]'); c.textContent = Math.round(S.zoom * 100) + '%'; sel.value = 'custom'; }
}
function scrollToIndex(i, smooth) {
  const p = S.pages[i]; if (!p) return;
  const v = views.get(p.id);
  viewer.scrollTo({ top: v.el.offsetTop - 12, behavior: smooth ? 'smooth' : 'auto' });
  S.current = i; updatePageUI();
}
let scrollRaf = 0;
viewer.addEventListener('scroll', () => {
  if (scrollRaf) return;
  scrollRaf = requestAnimationFrame(() => {
    scrollRaf = 0;
    const mid = viewer.scrollTop + viewer.clientHeight * 0.35;
    let cur = 0;
    for (let i = 0; i < S.pages.length; i++) {
      const v = views.get(S.pages[i].id);
      if (v.el.offsetTop <= mid) cur = i; else break;
    }
    if (cur !== S.current) { S.current = cur; updatePageUI(); }
  });
});
viewer.addEventListener('wheel', (e) => {
  if (!(e.ctrlKey || e.metaKey) || !hasDoc()) return;
  e.preventDefault();
  setZoom(S.zoom * Math.exp(-e.deltaY * 0.0025));
}, { passive: false });
let resizeT;
window.addEventListener('resize', () => {
  clearTimeout(resizeT);
  resizeT = setTimeout(() => { if (S.zoomMode !== 'custom' && S.pages.length) applyZoom(); }, 120);
});

/* ---------- thumbnails ---------- */
const THUMB_W = 132;
const thumbCache = new Map();
const thumbIO = new IntersectionObserver((entries) => {
  for (const en of entries) {
    const t = thumbs.get(en.target.dataset.id);
    if (t) { t.visible = en.isIntersecting; if (t.visible) renderThumb(t); }
  }
}, { root: $('#thumbs'), rootMargin: '300px 0px' });
function buildThumbs() {
  const host = $('#thumbs');
  const old = new Map(thumbs);
  thumbs.clear();
  const frag = document.createDocumentFragment();
  S.pages.forEach((p, i) => {
    let t = old.get(p.id);
    if (t) old.delete(p.id);
    else {
      t = { p, visible: false };
      t.canvas = el('canvas');
      t.box = el('div', { class: 'tbox' }, t.canvas);
      t.label = el('div', { class: 'tlabel' });
      t.el = el('div', { class: 'thumb', draggable: 'true', 'data-id': p.id, title: 'Drag to reorder' }, t.box, t.label);
      thumbIO.observe(t.el);
    }
    t.p = p;
    t.label.textContent = String(i + 1);
    const [w, h] = dispSize(p), sc = THUMB_W / Math.max(w, h * 0.77);
    t.box.style.width = Math.round(w * sc) + 'px'; t.box.style.height = Math.round(h * sc) + 'px';
    t.canvas.style.width = t.box.style.width; t.canvas.style.height = t.box.style.height;
    thumbs.set(p.id, t);
    frag.append(t.el);
  });
  for (const t of old.values()) { thumbIO.unobserve(t.el); t.el.remove(); }
  host.append(frag);
  for (const t of thumbs.values()) if (t.visible) renderThumb(t);
  updatePageUI();
}
async function renderThumb(t) {
  const p = t.p;
  const src = p.blank ? null : S.sources.get(p.src);
  const [w, h] = dispSize(p), sc = THUMB_W / Math.max(w, h * 0.77) * 2;
  const vp = vpFor(p, sc);
  const key = [p.src, p.idx, p.rot, src ? src.formVer : 0, Math.round(sc * 1000)].join('|');
  let base = thumbCache.get(key);
  if (!base) {
    base = document.createElement('canvas');
    base.width = Math.floor(vp.width); base.height = Math.floor(vp.height);
    const ctx = base.getContext('2d');
    ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, base.width, base.height);
    if (src) {
      try {
        const page = await src.doc.getPage(p.idx + 1);
        await page.render({ canvasContext: ctx, viewport: vp, annotationMode: pdfjsLib.AnnotationMode.ENABLE_STORAGE }).promise;
      } catch (e) { return; }
    }
    thumbCache.set(key, base);
    if (thumbCache.size > 200) thumbCache.delete(thumbCache.keys().next().value);
  }
  if (t.p !== p || thumbs.get(p.id) !== t) return;
  const c = t.canvas;
  c.width = base.width; c.height = base.height;
  const ctx = c.getContext('2d');
  ctx.drawImage(base, 0, 0);
  for (const a of p.annots) drawAnnot(ctx, a, vp.transform, { multiply: true });
}
const thumbTimers = new Map();
function scheduleThumb(p) {
  if (!p) return;
  clearTimeout(thumbTimers.get(p.id));
  thumbTimers.set(p.id, setTimeout(() => { const t = thumbs.get(p.id); if (t && t.visible) renderThumb(t); }, 250));
}
// thumbnail clicks & drag reorder
let dragPid = null;
$('#thumbs').addEventListener('click', (e) => {
  const th = e.target.closest('.thumb'); if (!th) return;
  scrollToIndex(S.pages.findIndex((p) => p.id === th.dataset.id));
});
$('#thumbs').addEventListener('dragstart', (e) => {
  const th = e.target.closest('.thumb'); if (!th) return;
  dragPid = th.dataset.id;
  e.dataTransfer.effectAllowed = 'move';
  e.dataTransfer.setData('text/x-pdfstudio-page', dragPid);
  th.classList.add('dragging');
});
$('#thumbs').addEventListener('dragend', () => {
  dragPid = null;
  $$('.thumb').forEach((t) => t.classList.remove('dragging', 'drop-before', 'drop-after'));
});
$('#thumbs').addEventListener('dragover', (e) => {
  if (!dragPid) return;
  const th = e.target.closest('.thumb'); if (!th) return;
  e.preventDefault();
  const r = th.getBoundingClientRect(), before = e.clientY < r.top + r.height / 2;
  $$('.thumb').forEach((t) => t.classList.remove('drop-before', 'drop-after'));
  th.classList.add(before ? 'drop-before' : 'drop-after');
});
$('#thumbs').addEventListener('drop', (e) => {
  if (!dragPid) return;
  const th = e.target.closest('.thumb'); if (!th) return;
  e.preventDefault(); e.stopPropagation();
  const r = th.getBoundingClientRect(), before = e.clientY < r.top + r.height / 2;
  const from = S.pages.findIndex((p) => p.id === dragPid);
  let to = S.pages.findIndex((p) => p.id === th.dataset.id) + (before ? 0 : 1);
  if (from < to) to--;
  if (from !== to && from >= 0) {
    pushUndo();
    const [p] = S.pages.splice(from, 1);
    S.pages.splice(to, 0, p);
    S.current = to;
    buildPages();
  }
  dragPid = null;
});

/* ---------- undo / redo ---------- */
const snapshot = () => ({ pages: structuredClone(S.pages) });
const structSig = () => S.pages.map((p) => p.id + ':' + p.rot).join(',');
function pushUndo() {
  S.undo.push(snapshot());
  if (S.undo.length > 150) S.undo.shift();
  S.redo.length = 0;
  setDirty(true);
  updateUI();
}
function restore(snap) {
  const before = structSig();
  S.pages = snap.pages;
  S.sel = null;
  if (structSig() !== before) buildPages();
  else {
    for (const p of S.pages) { const v = views.get(p.id); if (v) v.p = p; const t = thumbs.get(p.id); if (t) t.p = p; }
    redrawAll();
    for (const p of S.pages) scheduleThumb(p);
  }
  setDirty(true);
  updateUI();
}
function undo() { closeEditor(true); if (!S.undo.length) return; S.redo.push(snapshot()); restore(S.undo.pop()); }
function redo() { closeEditor(true); if (!S.redo.length) return; S.undo.push(snapshot()); restore(S.redo.pop()); }
function setDirty(d) {
  S.dirty = d;
  const name = S.mode === 'md' && S.md ? S.md.name : (S.pages.length ? S.name : '');
  document.title = (d ? '\u2022 ' : '') + (name ? name + ' \u2014 ' : '') + 'PDF Studio';
}
window.addEventListener('beforeunload', (e) => { if (S.dirty) { e.preventDefault(); e.returnValue = ''; } });

/* ---------- tools ---------- */
function setTool(t) {
  if (t === 'image') { $('#fileImage').click(); return; }
  if (t === 'sign') { openSignature(); return; }
  closeEditor(false);
  S.tool = t;
  if (t !== 'select' && t !== 'text') S.sel = null;
  document.body.className = document.body.className.replace(/\btool-\S+/g, '').trim();
  document.body.classList.toggle('tool-active', t !== 'read');
  document.body.classList.add('tool-' + t);
  $$('.tool').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.tool === t)));
  if (t !== 'read') { const s = window.getSelection(); if (s) s.removeAllRanges(); }
  redrawAll();
  updateProps();
}
$('#tools').addEventListener('click', (e) => { const b = e.target.closest('.tool'); if (b) setTool(b.dataset.tool); });

function select(p, a) {
  const prev = S.sel && pageById(S.sel.pid);
  S.sel = p && a ? { pid: p.id, aid: a.id } : null;
  if (prev) drawOverlay(prev);
  if (p) drawOverlay(p);
  updateProps();
}
function deleteSelected() {
  if (!S.sel) return;
  const p = pageById(S.sel.pid);
  if (!p) return;
  pushUndo();
  p.annots = p.annots.filter((a) => a.id !== S.sel.aid);
  S.sel = null;
  drawOverlay(p); scheduleThumb(p); updateProps();
}

/* ---------- props bar ---------- */
const SWATCH = {
  default: ['#111827', '#d6402b', '#2563eb', '#16a34a', '#9333ea'],
  highlight: ['#fde047', '#86efac', '#7dd3fc', '#f9a8d4', '#fdba74'],
  whiteout: ['#ffffff', '#000000', '#f3f4f6'],
};
function propTarget() {
  if (S.editing) return { a: S.editing.a, live: !S.editing.isNew, p: pageById(S.editing.pid) };
  if (S.sel) { const p = pageById(S.sel.pid), a = findAnnot(p, S.sel.aid); if (a) return { a, live: true, p }; }
  return null;
}
const TOOL_NAMES = { read: 'Read mode — select text to copy; click form fields to fill them', select: 'Select: click an edit to move it, drag the corner to resize, double-click text to edit', text: 'Text: click on the page to type', ink: 'Draw: drag on the page', highlight: 'Highlight: drag over an area', rect: 'Rectangle: drag on the page', whiteout: 'White-out: drag to cover content (covers visually; the original text stays in the file)' };
const TYPE_NAMES = { text: 'Text', ink: 'Drawing', rect: 'Rectangle', highlight: 'Highlight', whiteout: 'White-out', image: 'Image' };
function updateProps() {
  const tg = propTarget();
  const type = tg ? tg.a.type : (DEFAULT_DEFS[S.tool] ? S.tool : null);
  const vals = tg ? tg.a : (type ? S.defs[type] : {});
  $('#propsLabel').textContent = tg ? 'Selected: ' + TYPE_NAMES[tg.a.type] : (TOOL_NAMES[S.tool] || '');
  const showColor = type && type !== 'image';
  $('#propColorWrap').hidden = !showColor;
  $('#propFontWrap').hidden = type !== 'text';
  $('#propSizeWrap').hidden = type !== 'text';
  $('#propWidthWrap').hidden = !(type === 'ink' || type === 'rect');
  $('#btnDelAnnot').hidden = !(tg && tg.live && !S.editing);
  if (showColor) {
    const sw = $('#swatches');
    const list = SWATCH[type] || SWATCH.default;
    sw.replaceChildren(...list.map((c) => el('button', { class: 'sw', type: 'button', title: c, 'data-color': c, 'aria-pressed': String((vals.color || '').toLowerCase() === c), style: { background: c } })));
    $('#propColor').value = vals.color || '#000000';
  }
  if (type === 'text') { $('#propFont').value = vals.font; $('#propSize').value = vals.size; }
  if (vals.width != null) { $('#propWidth').value = vals.width; $('#propWidthVal').textContent = vals.width; }
}
let propUndoPending = false;
function applyProp(k, val, final = true) {
  const tg = propTarget();
  if (tg) {
    if (tg.live && !propUndoPending) { pushUndo(); propUndoPending = true; }
    tg.a[k] = val;
    if (S.defs[tg.a.type] && k in S.defs[tg.a.type]) S.defs[tg.a.type][k] = val;
    if (S.editing) styleEditor();
    drawOverlay(tg.p); scheduleThumb(tg.p);
  } else if (S.defs[S.tool]) {
    S.defs[S.tool][k] = val;
  }
  store.set('defs', S.defs);
  if (final) propUndoPending = false;
  updateProps();
  if (S.editing) S.editing.ta.focus();
}
$('#swatches').addEventListener('pointerdown', (e) => e.preventDefault()); // keep text editor focused
$('#swatches').addEventListener('click', (e) => { const b = e.target.closest('.sw'); if (b) applyProp('color', b.dataset.color); });
$('#propColor').addEventListener('input', (e) => applyProp('color', e.target.value, false));
$('#propColor').addEventListener('change', () => { propUndoPending = false; });
$('#propFont').addEventListener('change', (e) => applyProp('font', e.target.value));
$('#propSize').addEventListener('input', (e) => { const v = parseFloat(e.target.value); if (v >= 4 && v <= 144) applyProp('size', v, false); });
$('#propSize').addEventListener('change', () => { propUndoPending = false; });
$('#propWidth').addEventListener('input', (e) => applyProp('width', parseFloat(e.target.value), false));
$('#propWidth').addEventListener('change', () => { propUndoPending = false; });
$('#btnDelAnnot').addEventListener('click', deleteSelected);

/* ---------- text editor ---------- */
const BASELINE = 0.93; // approx. first-baseline offset in a textarea with line-height 1.2
function styleEditor() {
  const ed = S.editing; if (!ed) return;
  const p = pageById(ed.pid), vp = vpFor(p), a = ed.a, f = FONTS[a.font];
  const fs = a.size * vp.scale;
  const [vx, vy] = vp.convertToViewportPoint(a.x, a.y);
  Object.assign(ed.ta.style, { left: vx + 'px', top: (vy - fs * BASELINE) + 'px', font: `${f.weight} ${fs}px ${f.css}`, lineHeight: '1.2', color: a.color });
  ed.ta.style.width = '0px'; ed.ta.style.width = Math.max(fs, ed.ta.scrollWidth + fs * 0.6) + 'px';
  ed.ta.style.height = '0px'; ed.ta.style.height = ed.ta.scrollHeight + 'px';
}
function openTextEditor(p, a, isNew) {
  closeEditor(true);
  const v = views.get(p.id); if (!v) return;
  const ta = el('textarea', { class: 'text-editor', wrap: 'off', spellcheck: 'true', 'aria-label': 'Text' });
  ta.value = a.text;
  v.el.append(ta);
  S.editing = { pid: p.id, a, isNew, ta };
  S.sel = isNew ? null : { pid: p.id, aid: a.id };
  styleEditor();
  ta.addEventListener('input', styleEditor);
  ta.addEventListener('keydown', (e) => {
    e.stopPropagation();
    if (e.key === 'Escape' || (e.key === 'Enter' && (e.ctrlKey || e.metaKey))) { e.preventDefault(); closeEditor(true); }
  });
  ta.addEventListener('blur', () => setTimeout(() => {
    if (S.editing && S.editing.ta === ta && !document.activeElement?.closest('#subbar')) closeEditor(true);
  }, 0));
  drawOverlay(p); updateProps();
  ta.focus({ preventScroll: true });
  ta.setSelectionRange(ta.value.length, ta.value.length);
}
function closeEditor(commit) {
  const ed = S.editing; if (!ed) return;
  S.editing = null;
  ed.ta.remove();
  const p = pageById(ed.pid);
  if (!p) return;
  if (commit) {
    const text = sanitize(ed.a.font, ed.ta.value).replace(/\s+$/, '');
    if (ed.isNew) {
      if (text.trim()) { pushUndo(); ed.a.text = text; p.annots.push(ed.a); S.sel = { pid: p.id, aid: ed.a.id }; }
    } else {
      const live = findAnnot(p, ed.a.id);
      if (live && !text.trim()) { pushUndo(); p.annots = p.annots.filter((x) => x !== live); S.sel = null; }
      else if (live && text !== live.text) { pushUndo(); live.text = text; }
    }
  }
  drawOverlay(p); scheduleThumb(p); updateProps();
}

/* ---------- pointer interaction on pages ---------- */
let drag = null;
function localPt(e, elx) { const r = elx.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; }
pagesEl.addEventListener('pointerdown', (e) => {
  if (e.button !== 0 || S.tool === 'read') return;
  if (!e.target.matches('canvas.ov')) return;
  const pel = e.target.parentElement, p = pageById(pel.dataset.id);
  if (!p) return;
  e.preventDefault();
  const wasEditing = !!S.editing;
  if (S.editing) closeEditor(true);
  const vp = vpFor(p), pt = localPt(e, pel);
  const d = S.defs[S.tool];
  switch (S.tool) {
    case 'select': {
      if (S.sel && S.sel.pid === p.id) {
        const a = findAnnot(p, S.sel.aid);
        if (a && resizable(a)) {
          const b = bboxView(vp, a);
          if (Math.abs(pt.x - (b.x + b.w + 3)) < 10 && Math.abs(pt.y - (b.y + b.h + 3)) < 10) {
            drag = { kind: 'resize', p, a, vp, b, aspect: b.w / Math.max(1, b.h), pushed: false };
            break;
          }
        }
      }
      const hit = hitTest(p, vp, pt);
      select(hit ? p : null, hit);
      if (hit) drag = { kind: 'move', p, a: hit, vp, start: pt, orig: structuredClone(hit), pushed: false };
      break;
    }
    case 'text': {
      const hit = hitTest(p, vp, pt);
      if (hit && hit.type === 'text') { openTextEditor(p, hit, false); break; }
      if (wasEditing) { select(null); break; }
      const [x, y] = vp.convertToPdfPoint(pt.x, pt.y + d.size * vp.scale * 0.35);
      openTextEditor(p, { id: uid(), type: 'text', x, y, angle: p.rot, text: '', size: d.size, color: d.color, font: d.font }, true);
      break;
    }
    case 'ink': {
      const a = { id: uid(), type: 'ink', points: [vp.convertToPdfPoint(pt.x, pt.y)], color: d.color, width: d.width };
      S.temp = { pid: p.id, a };
      drag = { kind: 'ink', p, a, vp, last: pt };
      break;
    }
    case 'highlight': case 'rect': case 'whiteout': {
      const a = { id: uid(), type: S.tool, r: rectFromView(vp, pt.x, pt.y, pt.x, pt.y), color: d.color };
      if (S.tool === 'rect') a.width = d.width;
      S.temp = { pid: p.id, a };
      drag = { kind: 'box', p, a, vp, start: pt };
      break;
    }
  }
  if (drag) { try { e.target.setPointerCapture(e.pointerId); } catch {} }
});
pagesEl.addEventListener('pointermove', (e) => {
  if (!drag) return;
  const v = views.get(drag.p.id); if (!v) return;
  const pt = localPt(e, v.el), vp = drag.vp;
  switch (drag.kind) {
    case 'ink':
      if (Math.hypot(pt.x - drag.last.x, pt.y - drag.last.y) < 1.5) return;
      drag.last = pt;
      drag.a.points.push(vp.convertToPdfPoint(pt.x, pt.y));
      break;
    case 'box':
      drag.a.r = rectFromView(vp, drag.start.x, drag.start.y, pt.x, pt.y);
      break;
    case 'move': {
      if (!drag.pushed) { if (Math.hypot(pt.x - drag.start.x, pt.y - drag.start.y) < 3) return; pushUndo(); drag.pushed = true; drag.a = findAnnot(drag.p, drag.a.id) || drag.a; }
      const [sx, sy] = vp.convertToPdfPoint(drag.start.x, drag.start.y), [cx, cy] = vp.convertToPdfPoint(pt.x, pt.y);
      moveAnnot(drag.a, drag.orig, cx - sx, cy - sy);
      break;
    }
    case 'resize': {
      if (!drag.pushed) { pushUndo(); drag.pushed = true; drag.a = findAnnot(drag.p, drag.a.id) || drag.a; }
      const b = drag.b;
      let w = Math.max(6, pt.x - 3 - b.x), h = Math.max(6, pt.y - 3 - b.y);
      if (drag.a.type === 'image' && !e.shiftKey) { if (w / h > drag.aspect) h = w / drag.aspect; else w = h * drag.aspect; }
      drag.a.r = rectFromView(vp, b.x, b.y, b.x + w, b.y + h);
      break;
    }
  }
  drawOverlay(drag.p);
});
function endDrag() {
  if (!drag) return;
  const d = drag; drag = null;
  if (d.kind === 'ink' || d.kind === 'box') {
    S.temp = null;
    const a = d.a;
    let keep = true;
    if (d.kind === 'box') { const b = bboxView(d.vp, a); keep = b.w > 3 && b.h > 3; }
    if (keep) { pushUndo(); d.p.annots.push(a); }
  }
  drawOverlay(d.p); scheduleThumb(d.p); updateProps();
}
pagesEl.addEventListener('pointerup', endDrag);
pagesEl.addEventListener('pointercancel', endDrag);
pagesEl.addEventListener('dblclick', (e) => {
  if (S.tool !== 'select' && S.tool !== 'text') return;
  const pel = e.target.closest('.page'); if (!pel || e.target.tagName === 'TEXTAREA') return;
  const p = pageById(pel.dataset.id), vp = vpFor(p), hit = hitTest(p, vp, localPt(e, pel));
  if (hit && hit.type === 'text') openTextEditor(p, hit, false);
});
function moveAnnot(a, o, dx, dy) {
  if (a.type === 'text') { a.x = o.x + dx; a.y = o.y + dy; }
  else if (a.type === 'ink') a.points = o.points.map(([x, y]) => [x + dx, y + dy]);
  else a.r = { x0: o.r.x0 + dx, y0: o.r.y0 + dy, x1: o.r.x1 + dx, y1: o.r.y1 + dy };
}
// Read mode: clicking a form field jumps to it in the Form panel
pagesEl.addEventListener('click', (e) => {
  if (S.tool !== 'read') return;
  const sel = window.getSelection(); if (sel && !sel.isCollapsed) return;
  const pel = e.target.closest('.page'); if (!pel) return;
  const p = pageById(pel.dataset.id); if (!p || p.blank) return;
  const src = S.sources.get(p.src); if (!src || !src.fields) return;
  const [x, y] = vpFor(p).convertToPdfPoint(...Object.values(localPt(e, pel)));
  for (const [name, arr] of Object.entries(src.fields)) {
    for (const w of arr) {
      if (w.page !== p.idx || !w.rect) continue;
      const [a, b, c, d] = w.rect;
      if (x >= Math.min(a, c) && x <= Math.max(a, c) && y >= Math.min(b, d) && y <= Math.max(b, d)) { focusField(src.id, name); return; }
    }
  }
});

/* ---------- images & signatures ---------- */
async function addImageFromBlob(blob, kind) {
  const url = URL.createObjectURL(blob);
  const img = await loadImg(url);
  const maxDim = kind === 'sig' ? 1600 : 2500;
  let type = blob.type === 'image/png' ? 'png' : (blob.type === 'image/jpeg' ? 'jpg' : null);
  let bytes = new Uint8Array(await blob.arrayBuffer());
  const big = Math.max(img.naturalWidth, img.naturalHeight) > maxDim;
  if (type !== 'png' || big) { // re-encode (also bakes in JPEG camera rotation)
    const sc = Math.min(1, maxDim / Math.max(img.naturalWidth, img.naturalHeight));
    const c = document.createElement('canvas');
    c.width = Math.round(img.naturalWidth * sc); c.height = Math.round(img.naturalHeight * sc);
    c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
    const asJpg = type === 'jpg';
    const b2 = await canvasToBlob(c, asJpg ? 'image/jpeg' : 'image/png', 0.9);
    bytes = new Uint8Array(await b2.arrayBuffer());
    type = asJpg ? 'jpg' : 'png';
  }
  const id = uid();
  S.images.set(id, { bytes, type, el: img });
  return id;
}
function placeImage(id, widthPts) {
  if (!S.pages.length) return;
  const p = S.pages[S.current], v = views.get(p.id), vp = vpFor(p), im = S.images.get(id);
  const er = v.el.getBoundingClientRect(), vr = viewer.getBoundingClientRect();
  const cx = clamp((Math.max(er.left, vr.left) + Math.min(er.right, vr.right)) / 2 - er.left, 0, vp.width);
  const cy = clamp((Math.max(er.top, vr.top) + Math.min(er.bottom, vr.bottom)) / 2 - er.top, 0, vp.height);
  let w = Math.min(widthPts * vp.scale, vp.width * 0.8);
  let h = w * im.el.naturalHeight / im.el.naturalWidth;
  if (h > vp.height * 0.8) { h = vp.height * 0.8; w = h * im.el.naturalWidth / im.el.naturalHeight; }
  const a = { id: uid(), type: 'image', img: id, angle: p.rot, r: rectFromView(vp, cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2) };
  pushUndo();
  p.annots.push(a);
  setTool('select');
  select(p, a);
  scheduleThumb(p);
  toast('Drag to move · drag the corner square to resize');
}
$('#fileImage').addEventListener('change', async (e) => {
  const f = e.target.files[0]; e.target.value = '';
  if (!f) return;
  try { const id = await addImageFromBlob(f, 'img'); placeImage(id, 200); }
  catch (err) { toast(err.message || 'Could not add image.', 'error'); }
});

// Signature dialog
const sigDlg = $('#sigDlg'), pad = $('#sigPad');
let sigStrokes = [], sigColor = '#111827', sigTab = 'draw', sigSavedSel = null;
pad.width = 1120; pad.height = 400;
function drawPad() {
  const ctx = pad.getContext('2d');
  ctx.clearRect(0, 0, pad.width, pad.height);
  ctx.strokeStyle = '#e5e7eb'; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(40, 300); ctx.lineTo(1080, 300); ctx.stroke();
  ctx.strokeStyle = sigColor; ctx.lineWidth = 5; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
  for (const s of sigStrokes) {
    ctx.beginPath(); ctx.moveTo(s[0][0], s[0][1]);
    if (s.length === 1) ctx.lineTo(s[0][0] + 0.1, s[0][1]);
    for (let i = 1; i < s.length - 1; i++) {
      const mx = (s[i][0] + s[i + 1][0]) / 2, my = (s[i][1] + s[i + 1][1]) / 2;
      ctx.quadraticCurveTo(s[i][0], s[i][1], mx, my);
    }
    if (s.length > 1) ctx.lineTo(s[s.length - 1][0], s[s.length - 1][1]);
    ctx.stroke();
  }
}
let padDown = false;
const padPt = (e) => { const r = pad.getBoundingClientRect(); return [(e.clientX - r.left) * pad.width / r.width, (e.clientY - r.top) * pad.height / r.height]; };
pad.addEventListener('pointerdown', (e) => { padDown = true; pad.setPointerCapture(e.pointerId); sigStrokes.push([padPt(e)]); drawPad(); });
pad.addEventListener('pointermove', (e) => { if (!padDown) return; sigStrokes[sigStrokes.length - 1].push(padPt(e)); drawPad(); });
pad.addEventListener('pointerup', () => { padDown = false; });
$('#sigClear').addEventListener('click', () => { sigStrokes = []; drawPad(); });
$('#sigText').addEventListener('input', (e) => { $('#sigTypePreview').textContent = e.target.value; });
$$('[data-sigcolor]').forEach((b) => b.addEventListener('click', () => { sigColor = b.dataset.sigcolor; drawPad(); $('#sigTypePreview').style.color = sigColor; }));
function setSigTab(t) {
  sigTab = t;
  $$('[data-sigtab]').forEach((b) => b.classList.toggle('active', b.dataset.sigtab === t));
  $$('[data-sigpanel]').forEach((p) => { p.hidden = p.dataset.sigpanel !== t; });
  if (t === 'type') setTimeout(() => $('#sigText').focus(), 0);
}
$$('[data-sigtab]').forEach((b) => b.addEventListener('click', () => setSigTab(b.dataset.sigtab)));
function renderSavedSigs() {
  const list = store.get('signatures', []);
  $('#sigSavedTab').hidden = !list.length;
  $('#sigSavedList').replaceChildren(...list.map((url, i) => {
    const item = el('div', { class: 'item' + (sigSavedSel === i ? ' sel' : ''), title: 'Use this signature' }, el('img', { src: url, alt: 'Saved signature' }));
    const del = el('button', { type: 'button', class: 'del', title: 'Forget this signature' }, '×');
    del.addEventListener('click', (e) => { e.stopPropagation(); const l = store.get('signatures', []); l.splice(i, 1); store.set('signatures', l); sigSavedSel = null; renderSavedSigs(); if (!l.length) setSigTab('draw'); });
    item.addEventListener('click', () => { sigSavedSel = i; renderSavedSigs(); });
    item.addEventListener('dblclick', () => { sigSavedSel = i; useSignature(); });
    item.append(del);
    return item;
  }));
}
function openSignature() {
  if (!S.pages.length) return;
  sigStrokes = []; sigSavedSel = null; drawPad();
  renderSavedSigs();
  setSigTab(store.get('signatures', []).length ? 'saved' : 'draw');
  sigDlg.showModal();
}
function trimCanvas(c) {
  const ctx = c.getContext('2d');
  const { data, width, height } = ctx.getImageData(0, 0, c.width, c.height);
  let x0 = width, y0 = height, x1 = -1, y1 = -1;
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    if (data[(y * width + x) * 4 + 3] > 8) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
  }
  if (x1 < 0) return null;
  const m = 6, out = document.createElement('canvas');
  out.width = x1 - x0 + 1 + 2 * m; out.height = y1 - y0 + 1 + 2 * m;
  out.getContext('2d').drawImage(c, x0 - m, y0 - m, out.width, out.height, 0, 0, out.width, out.height);
  return out;
}
async function useSignature() {
  let dataUrl = null;
  if (sigTab === 'saved') {
    const list = store.get('signatures', []);
    if (sigSavedSel == null) { toast('Click a saved signature first.'); return; }
    dataUrl = list[sigSavedSel];
  } else {
    const c = document.createElement('canvas');
    if (sigTab === 'draw') {
      if (!sigStrokes.length) { toast('Draw your signature first.'); return; }
      c.width = pad.width; c.height = pad.height;
      const ctx = c.getContext('2d');
      ctx.strokeStyle = sigColor; ctx.lineWidth = 5; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
      for (const s of sigStrokes) {
        ctx.beginPath(); ctx.moveTo(s[0][0], s[0][1]);
        if (s.length === 1) ctx.lineTo(s[0][0] + 0.1, s[0][1]);
        for (let i = 1; i < s.length - 1; i++) ctx.quadraticCurveTo(s[i][0], s[i][1], (s[i][0] + s[i + 1][0]) / 2, (s[i][1] + s[i + 1][1]) / 2);
        if (s.length > 1) ctx.lineTo(s[s.length - 1][0], s[s.length - 1][1]);
        ctx.stroke();
      }
    } else {
      const txt = $('#sigText').value.trim();
      if (!txt) { toast('Type your name first.'); return; }
      const font = getComputedStyle($('#sigTypePreview')).fontFamily;
      const ctx0 = c.getContext('2d'); ctx0.font = `96px ${font}`;
      c.width = Math.ceil(ctx0.measureText(txt).width + 60); c.height = 180;
      const ctx = c.getContext('2d'); ctx.font = `96px ${font}`; ctx.fillStyle = sigColor; ctx.textBaseline = 'middle';
      ctx.fillText(txt, 30, 90);
    }
    const t = trimCanvas(c);
    if (!t) { toast('Signature is empty.'); return; }
    dataUrl = t.toDataURL('image/png');
    if ($('#sigRemember').checked) {
      const list = store.get('signatures', []).filter((u) => u !== dataUrl);
      list.unshift(dataUrl); store.set('signatures', list.slice(0, 6));
    }
  }
  sigDlg.close();
  const blob = new Blob([b64ToBytes(dataUrl)], { type: 'image/png' });
  const id = await addImageFromBlob(blob, 'sig');
  placeImage(id, 160);
}
$('#sigUse').addEventListener('click', useSignature);

/* ---------- page operations ---------- */
function curP() { return S.pages[S.current]; }
function rotatePage(delta) {
  const p = curP(); if (!p) return;
  pushUndo();
  p.rot = (p.rot + delta + 360) % 360;
  buildPages();
  if (S.zoomMode !== 'custom') applyZoom();
  scrollToIndex(S.current);
}
function movePage(dir) {
  const i = S.current, j = i + dir;
  if (j < 0 || j >= S.pages.length) return;
  pushUndo();
  [S.pages[i], S.pages[j]] = [S.pages[j], S.pages[i]];
  S.current = j;
  buildPages(); scrollToIndex(j);
}
function deletePages(idxs) {
  idxs = [...new Set(idxs)].filter((i) => i >= 0 && i < S.pages.length);
  if (!idxs.length) return;
  if (idxs.length >= S.pages.length) { toast('A PDF needs at least one page.', 'error'); return; }
  pushUndo();
  const del = new Set(idxs.map((i) => S.pages[i].id));
  S.pages = S.pages.filter((p) => !del.has(p.id));
  S.current = clamp(Math.min(...idxs), 0, S.pages.length - 1);
  buildPages(); scrollToIndex(S.current);
  toast(`Deleted ${idxs.length} page${idxs.length > 1 ? 's' : ''} — Ctrl+Z to undo`);
}
function insertBlank() {
  const cp = curP(); if (!cp) return;
  pushUndo();
  const w = cp.view[2] - cp.view[0], h = cp.view[3] - cp.view[1];
  const p = { id: uid(), src: null, idx: 0, view: [0, 0, w, h], rot: cp.rot, blank: true, annots: [] };
  S.pages.splice(S.current + 1, 0, p);
  S.current++;
  buildPages(); scrollToIndex(S.current);
}
function parseRange(str, n) {
  const out = [];
  for (const part of str.split(/[,;\s]+/).filter(Boolean)) {
    const m = /^(\d+)?\s*-\s*(\d+)?$/.exec(part);
    if (m) {
      const a = m[1] ? +m[1] : 1, b = m[2] ? +m[2] : n;
      if (a < 1 || b > n || a > b) return null;
      for (let i = a; i <= b; i++) out.push(i - 1);
    } else if (/^\d+$/.test(part)) {
      const v = +part; if (v < 1 || v > n) return null; out.push(v - 1);
    } else return null;
  }
  return out.length ? out : null;
}
$('#btnRotL').addEventListener('click', () => rotatePage(-90));
$('#btnRotR').addEventListener('click', () => rotatePage(90));
$('#btnMoveUp').addEventListener('click', () => movePage(-1));
$('#btnMoveDown').addEventListener('click', () => movePage(1));
$('#btnBlank').addEventListener('click', insertBlank);
$('#btnDelPage').addEventListener('click', () => deletePages([S.current]));
$('#btnExtract').addEventListener('click', () => {
  $('#pagesDlgCount').textContent = S.pages.length;
  $('#pagesRange').value = String(S.current + 1);
  $('#pagesDlg').showModal();
  $('#pagesRange').select();
});
$('#pagesDelete').addEventListener('click', () => {
  const r = parseRange($('#pagesRange').value, S.pages.length);
  if (!r) { toast('Please enter a valid page range.', 'error'); return; }
  $('#pagesDlg').close();
  deletePages(r);
});
$('#pagesExtract').addEventListener('click', async () => {
  const txt = $('#pagesRange').value;
  const r = parseRange(txt, S.pages.length);
  if (!r) { toast('Please enter a valid page range.', 'error'); return; }
  $('#pagesDlg').close();
  const base = S.name.replace(/\.pdf$/i, '');
  await saveBytes(() => exportPdf(r.map((i) => S.pages[i])), `${base} (pages ${txt.replace(/\s+/g, '')}).pdf`, false);
});

/* ---------- forms ---------- */
const FORM_TYPES = new Set(['text', 'checkbox', 'radiobutton', 'combobox', 'listbox']);
function formFieldsOf(src) {
  if (!src.fields) return [];
  return Object.entries(src.fields)
    .map(([name, arr]) => [name, arr.filter((w) => w.id && FORM_TYPES.has(w.type) && !w.hidden)])
    .filter(([, arr]) => arr.length);
}
let formRenderT;
function formChanged(src) {
  src.formChanged = true;
  setDirty(true);
  clearTimeout(formRenderT);
  formRenderT = setTimeout(() => {
    src.formVer++;
    for (const v of views.values()) if (v.visible && v.p.src === src.id) renderPage(v);
    for (const t of thumbs.values()) if (t.visible && t.p.src === src.id) renderThumb(t);
  }, 200);
}
function buildFormPanel() {
  const host = $('#formPanel');
  host.replaceChildren();
  const used = [...new Set(S.pages.filter((p) => !p.blank).map((p) => p.src))].map((id) => S.sources.get(id));
  let total = 0;
  for (const src of used) {
    const fields = formFieldsOf(src);
    if (!fields.length) continue;
    total += fields.length;
    if (used.length > 1) host.append(el('div', { class: 'form-src' }, src.name));
    const storage = src.doc.annotationStorage;
    for (const [name, arr] of fields) {
      const w0 = arr[0];
      const box = el('div', { class: 'ff', 'data-src': src.id, 'data-name': name });
      const label = el('label', { class: 'name' }, name);
      box.append(label);
      const readOnly = !w0.editable;
      const goto = () => { const i = S.pages.findIndex((p) => p.src === src.id && p.idx === w0.page); if (i >= 0 && i !== S.current) scrollToIndex(i, true); };
      if (w0.type === 'text') {
        const cur = storage.getValue(w0.id, { value: w0.value ?? '' }).value ?? '';
        const inp = el('input', { type: 'text', value: String(cur), disabled: readOnly });
        inp.addEventListener('input', () => { for (const w of arr) storage.setValue(w.id, { value: inp.value }); formChanged(src); });
        inp.addEventListener('focus', goto);
        box.append(inp);
      } else if (w0.type === 'checkbox' && arr.length === 1) {
        const cur = storage.getValue(w0.id, { value: w0.value != null && w0.value !== 'Off' && w0.value === w0.exportValues }).value;
        const cb = el('input', { type: 'checkbox', checked: !!cur, disabled: readOnly });
        cb.addEventListener('change', () => { storage.setValue(w0.id, { value: cb.checked }); formChanged(src); });
        cb.addEventListener('focus', goto);
        label.remove();
        box.append(el('label', { class: 'opt' }, cb, name));
      } else if (w0.type === 'checkbox' || w0.type === 'radiobutton') {
        const group = 'g' + uid();
        const numericOpts = arr.every((w) => /^\d+$/.test(String(w.exportValues)));
        arr.forEach((w, i) => {
          const cur = storage.getValue(w.id, { value: w.value != null && w.value === w.exportValues }).value;
          const r = el('input', { type: w0.type === 'radiobutton' ? 'radio' : 'checkbox', name: group, checked: !!cur, disabled: readOnly });
          r.addEventListener('change', () => {
            if (w0.type === 'radiobutton') for (const o of arr) storage.setValue(o.id, { value: o === w });
            else for (const o of arr) storage.setValue(o.id, { value: o === w && r.checked });
            if (w0.type === 'checkbox') $$('input', box).forEach((x) => { if (x !== r) x.checked = false; });
            formChanged(src);
          });
          r.addEventListener('focus', goto);
          box.append(el('label', { class: 'opt' }, r, numericOpts ? `Option ${i + 1}` : String(w.exportValues ?? `Option ${i + 1}`)));
        });
      } else if (w0.type === 'combobox' || w0.type === 'listbox') {
        const items = w0.items || [];
        let cur = storage.getValue(w0.id, { value: w0.value }).value;
        if (Array.isArray(cur)) cur = cur[0];
        const s = el('select', { disabled: readOnly }, el('option', { value: '' }, '—'),
          ...items.map((it) => el('option', { value: it.exportValue, selected: it.exportValue === cur }, it.displayValue ?? it.exportValue)));
        s.addEventListener('change', () => { for (const w of arr) storage.setValue(w.id, { value: s.value }); formChanged(src); });
        s.addEventListener('focus', goto);
        box.append(s);
      }
      host.append(box);
    }
  }
  if (!total) host.append(el('div', { class: 'form-empty' }, 'This document has no fillable form fields. Use the Text tool to type anywhere on the page.'));
  const badge = $('#formBadge');
  badge.hidden = !total; badge.textContent = total;
}
function focusField(srcId, name) {
  showTab('form');
  $('#sidebar').classList.remove('collapsed');
  const box = $$('.ff', $('#formPanel')).find((b) => b.dataset.src === srcId && b.dataset.name === name);
  if (!box) return;
  box.scrollIntoView({ block: 'center', behavior: 'smooth' });
  const inp = box.querySelector('input,select');
  if (inp) inp.focus({ preventScroll: true });
  box.classList.add('focus-flash'); setTimeout(() => box.classList.remove('focus-flash'), 900);
}
function showTab(name) {
  $$('.tabs .tab[data-tab]').forEach((t) => t.classList.toggle('active', t.dataset.tab === name));
  $$('[data-panel]').forEach((p) => { p.hidden = p.dataset.panel !== name; });
}
$$('.tab[data-tab]').forEach((t) => t.addEventListener('click', () => showTab(t.dataset.tab)));

/* ---------- search ---------- */
function clearSearch() { S.search = { q: '', hits: [], cur: -1, token: S.search.token + 1 }; $('#searchCount').textContent = ''; }
async function runSearch(q) {
  if (S.mode === 'md') { mdFind(q); return; }
  const token = ++S.search.token;
  S.search.q = q; S.search.hits = []; S.search.cur = -1;
  redrawAll();
  if (!q.trim()) { $('#searchCount').textContent = ''; return; }
  const needle = q.toLowerCase();
  $('#searchCount').textContent = '…';
  const hits = [];
  for (const p of S.pages) {
    if (p.blank) continue;
    const tc = await getText(p);
    if (token !== S.search.token) return;
    let str = ''; const map = [];
    tc.items.forEach((it, ii) => {
      if (it.str == null) return;
      for (let ci = 0; ci < it.str.length; ci++) { map.push([ii, ci]); str += it.str[ci]; }
      if (it.hasEOL) { map.push(null); str += ' '; }
    });
    const low = str.toLowerCase();
    let pos = low.indexOf(needle);
    while (pos !== -1) {
      const quads = []; let seg = null;
      for (let k = pos; k < pos + needle.length; k++) {
        const m = map[k]; if (!m) continue;
        if (!seg || seg.ii !== m[0]) { seg = { ii: m[0], c0: m[1], c1: m[1] + 1 }; quads.push(seg); } else seg.c1 = m[1] + 1;
      }
      hits.push({ pid: p.id, quads: quads.map((s) => itemQuad(tc.items[s.ii], s.c0, s.c1)) });
      pos = low.indexOf(needle, pos + Math.max(1, needle.length));
    }
  }
  S.search.hits = hits;
  if (!hits.length) { $('#searchCount').textContent = '0/0'; redrawAll(); return; }
  const startIdx = hits.findIndex((h) => S.pages.findIndex((p) => p.id === h.pid) >= S.current);
  gotoHit(startIdx >= 0 ? startIdx : 0);
}
function itemQuad(it, c0, c1) {
  const [a, b, c, d, e, f] = it.transform;
  const len = Math.max(1, it.str.length);
  const fx = Math.hypot(a, b) || 1, dir = [a / fx, b / fx];
  const fy = Math.hypot(c, d) || 1, up = [c / fy, d / fy];
  const h = it.height || fy;
  const u0 = it.width * c0 / len, u1 = it.width * c1 / len, v0 = -0.22 * h, v1 = 0.95 * h;
  const P = (u, v) => [e + dir[0] * u + up[0] * v, f + dir[1] * u + up[1] * v];
  return [P(u0, v0), P(u1, v0), P(u1, v1), P(u0, v1)];
}
function gotoHit(i) {
  if (S.mode === 'md') { mdGoto(i); return; }
  const hits = S.search.hits; if (!hits.length) return;
  S.search.cur = (i + hits.length) % hits.length;
  const h = hits[S.search.cur];
  $('#searchCount').textContent = `${S.search.cur + 1}/${hits.length}`;
  const p = pageById(h.pid), v = views.get(h.pid), vp = vpFor(p);
  const b = viewBoxOf(vp, h.quads.flat());
  viewer.scrollTo({ top: v.el.offsetTop + b.y - viewer.clientHeight / 3, left: Math.max(0, v.el.offsetLeft + b.x - viewer.clientWidth / 2) });
  redrawAll();
}
let searchT;
$('#searchInput').addEventListener('input', (e) => { clearTimeout(searchT); searchT = setTimeout(() => runSearch(e.target.value), 250); });
$('#searchInput').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') {
    e.preventDefault();
    if (S.search.q !== e.target.value) { clearTimeout(searchT); runSearch(e.target.value); }
    else gotoHit(S.search.cur + (e.shiftKey ? -1 : 1));
  } else if (e.key === 'Escape') { e.target.value = ''; clearSearch(); redrawAll(); viewer.focus(); }
});
$('#btnNext').addEventListener('click', () => gotoHit(S.search.cur + 1));
$('#btnPrev').addEventListener('click', () => gotoHit(S.search.cur - 1));

/* ---------- export (save) ---------- */
async function exportPdf(list) {
  closeEditor(true);
  await fontsReady;
  const used = [...new Set(list.filter((p) => !p.blank).map((p) => p.src))];
  const libs = new Map(), raster = new Set();
  for (const sid of used) {
    const s = S.sources.get(sid);
    try {
      const d = await PDFDocument.load(s.bytes, { updateMetadata: false });
      applyFormValues(s, d);
      libs.set(sid, d);
    }
    catch (e) {
      if (/encrypt/i.test(String(e && (e.message || e.name)))) { s.encrypted = true; raster.add(sid); }
      else throw e;
    }
  }
  if (raster.size && !S.rasterOk) {
    if (!confirm('This PDF is protected (encrypted), so its original pages can’t be rewritten.\n\nPDF Studio can still save your edits, but those pages will be saved as high-resolution images (text in them won’t be selectable).\n\nContinue?')) { const err = new Error('cancelled'); err.name = 'AbortError'; throw err; }
    S.rasterOk = true;
  }
  const baseId = used.find((id) => libs.has(id));
  let keepBase = false;
  if (baseId) {
    const bs = S.sources.get(baseId), bd = libs.get(baseId), n = bd.getPageCount();
    const idxs = list.filter((p) => p.src === baseId).map((p) => p.idx);
    const full = idxs.length === n && new Set(idxs).size === n;
    keepBase = formFieldsOf(bs).length > 0 || (used.length === 1 && full);
  }
  const out = keepBase ? libs.get(baseId) : await PDFDocument.create();
  const pagesFor = new Map();
  if (keepBase) pagesFor.set(baseId, new Map(out.getPages().map((pg, i) => [i, pg])));
  for (const sid of used) {
    if ((keepBase && sid === baseId) || raster.has(sid)) continue;
    const d = libs.get(sid);
    if (formFieldsOf(S.sources.get(sid)).length) { try { d.getForm().flatten(); } catch (e) { console.warn('flatten failed', e); } }
    const idxs = [...new Set(list.filter((p) => p.src === sid).map((p) => p.idx))];
    const cps = await out.copyPages(d, idxs);
    pagesFor.set(sid, new Map(idxs.map((ix, k) => [ix, cps[k]])));
  }
  const seen = new Set(), final = [];
  for (const p of list) {
    let pg;
    if (p.blank) {
      pg = PDFPage.create(out);
      pg.setMediaBox(p.view[0], p.view[1], p.view[2] - p.view[0], p.view[3] - p.view[1]);
    } else if (raster.has(p.src)) {
      pg = await rasterPage(out, p);
    } else {
      const k = p.src + '|' + p.idx;
      pg = pagesFor.get(p.src).get(p.idx);
      if (seen.has(k)) [pg] = await out.copyPages(libs.get(p.src), [p.idx]);
      seen.add(k);
    }
    pg.setRotation(degrees(p.rot));
    final.push([pg, p]);
  }
  if (keepBase) while (out.getPageCount()) out.removePage(out.getPageCount() - 1);
  for (const [pg] of final) out.addPage(pg);
  const fonts = {}, imgs = {};
  for (const [pg, p] of final) await drawAnnotsLib(out, pg, p, fonts, imgs);
  if (!keepBase) out.setTitle(S.name.replace(/\.pdf$/i, ''));
  out.setProducer('PDF Studio');
  out.setModificationDate(new Date());
  return out.save();
}
// Copy values typed into the Form panel (kept in PDF.js's annotation storage) into the pdf-lib document.
function applyFormValues(src, doc) {
  if (!src.formChanged) return;
  const storage = src.doc.annotationStorage;
  const get = (w) => storage.getValue(w.id, { value: undefined }).value;
  let form;
  try { form = doc.getForm(); } catch { return; }
  for (const [name, arr] of formFieldsOf(src)) {
    const w0 = arr[0];
    try {
      const field = form.getField(name);
      if (w0.type === 'text') {
        const v = get(w0);
        if (v !== undefined) field.setText(String(v));
      } else if (w0.type === 'checkbox' || w0.type === 'radiobutton') {
        const states = arr.map(get);
        if (states.every((x) => x === undefined)) continue;
        const k = states.findIndex((x) => x === true);
        const af = field.acroField, widgets = af.getWidgets();
        const on = k >= 0 && widgets[k] ? widgets[k].getOnValue() : null;
        af.setValue(on || PDFName.of('Off'));
      } else if (w0.type === 'combobox' || w0.type === 'listbox') {
        let v = get(w0);
        if (v === undefined) continue;
        if (Array.isArray(v)) v = v[0];
        if (!v) { field.clear(); continue; }
        const item = (w0.items || []).find((i) => i.exportValue === v);
        try { field.select(item && item.displayValue != null ? item.displayValue : v); } catch { field.select(v); }
      }
    } catch (e) { console.warn('Could not save form field', name, e); }
  }
  try { form.updateFieldAppearances(); } catch (e) { console.warn('appearance update failed', e); }
}
async function rasterPage(out, p) {
  const s = S.sources.get(p.src);
  const page = await s.doc.getPage(p.idx + 1);
  const vp = page.getViewport({ scale: 2.5, rotation: 0 });
  const c = document.createElement('canvas');
  c.width = Math.ceil(vp.width); c.height = Math.ceil(vp.height);
  const ctx = c.getContext('2d');
  ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, c.width, c.height);
  await page.render({ canvasContext: ctx, viewport: vp, annotationMode: pdfjsLib.AnnotationMode.ENABLE_STORAGE }).promise;
  const blob = await canvasToBlob(c, 'image/jpeg', 0.9);
  c.width = 0;
  const img = await out.embedJpg(new Uint8Array(await blob.arrayBuffer()));
  const [x0, y0, x1, y1] = p.view;
  const pg = PDFPage.create(out);
  pg.setMediaBox(x0, y0, x1 - x0, y1 - y0);
  pg.drawImage(img, { x: x0, y: y0, width: x1 - x0, height: y1 - y0 });
  return pg;
}
async function drawAnnotsLib(out, pg, p, fonts, imgs) {
  if (!p.annots.length) return;
  pg.node.normalize();
  const list = [...p.annots.filter((a) => a.type === 'highlight'), ...p.annots.filter((a) => a.type !== 'highlight')];
  for (const a of list) {
    const col = hexToRgb(a.color);
    const R = a.r && { x: a.r.x0, y: a.r.y0, width: a.r.x1 - a.r.x0, height: a.r.y1 - a.r.y0 };
    switch (a.type) {
      case 'highlight': pg.drawRectangle({ ...R, color: col, blendMode: BlendMode.Multiply }); break;
      case 'whiteout': pg.drawRectangle({ ...R, color: col }); break;
      case 'rect': pg.drawRectangle({ ...R, borderColor: col, borderWidth: a.width }); break;
      case 'ink': {
        const ops = [pushGraphicsState(), setStrokingColor(col), setLineWidth(a.width),
          setLineCap(LineCapStyle.Round), setLineJoin(LineJoinStyle.Round), moveTo(a.points[0][0], a.points[0][1])];
        if (a.points.length === 1) ops.push(lineTo(a.points[0][0], a.points[0][1]));
        for (let i = 1; i < a.points.length; i++) ops.push(lineTo(a.points[i][0], a.points[i][1]));
        ops.push(stroke(), popGraphicsState());
        pg.pushOperators(...ops);
        break;
      }
      case 'text': {
        const f = fonts[a.font] || (fonts[a.font] = await out.embedFont(StandardFonts[FONTS[a.font].pdf]));
        const rad = a.angle * Math.PI / 180, lh = a.size * 1.2;
        a.text.split('\n').forEach((ln, i) => {
          if (!ln) return;
          pg.drawText(sanitize(a.font, ln), { x: a.x + Math.sin(rad) * lh * i, y: a.y - Math.cos(rad) * lh * i, size: a.size, font: f, color: col, rotate: degrees(a.angle) });
        });
        break;
      }
      case 'image': {
        const im = S.images.get(a.img); if (!im) break;
        const e = imgs[a.img] || (imgs[a.img] = im.type === 'png' ? await out.embedPng(im.bytes) : await out.embedJpg(im.bytes));
        const pl = imgPlace(a);
        pg.drawImage(e, { x: pl.x, y: pl.y, width: pl.w, height: pl.h, rotate: degrees(a.angle) });
        break;
      }
    }
  }
}
let saving = false;
const PDF_TYPE = { description: 'PDF document', accept: { 'application/pdf': ['.pdf'] } };
const MD_TYPE = { description: 'Markdown document', accept: { 'text/markdown': ['.md', '.markdown'] } };
async function saveBytes(make, suggested, markClean, type = PDF_TYPE) {
  if (saving) return;
  saving = true;
  let handle = null;
  try {
    if (window.showSaveFilePicker) {
      try {
        handle = await window.showSaveFilePicker({ suggestedName: suggested, id: type === PDF_TYPE ? 'pdfstudio' : 'pdfstudio-md', types: [type] });
      } catch (e) { if (e.name === 'AbortError') return; handle = null; }
    }
    toast('Saving…', '', 0);
    document.body.style.cursor = 'progress';
    const bytes = await make();
    if (handle) {
      const w = await handle.createWritable();
      await w.write(bytes); await w.close();
      toast('Saved “' + handle.name + '”');
    } else {
      const url = URL.createObjectURL(new Blob([bytes], { type: Object.keys(type.accept)[0] }));
      const a = el('a', { href: url, download: suggested });
      document.body.append(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 60000);
      toast('Saved to your Downloads folder as “' + suggested + '”');
    }
    if (markClean) setDirty(false);
  } catch (e) {
    if (e.name !== 'AbortError') { console.error(e); toast('Could not save: ' + (e.message || e), 'error', 6000); }
    else hideToast();
  } finally {
    saving = false;
    document.body.style.cursor = '';
  }
}
function save() {
  if (S.mode === 'md') { saveBytes(() => S.md.text, S.md.name, true, MD_TYPE); return; }
  if (S.pages.length) saveBytes(() => exportPdf(S.pages), S.name.toLowerCase().endsWith('.pdf') ? S.name : S.name + '.pdf', true); }
async function printDoc() {
  if (S.mode === 'md') { printMd(); return; }
  if (!S.pages.length) return;
  toast('Preparing…', '', 0);
  try {
    const bytes = await exportPdf(S.pages);
    const url = URL.createObjectURL(new Blob([bytes], { type: 'application/pdf' }));
    const w = window.open(url, '_blank');
    if (!w) {
      const a = el('a', { href: url, download: S.name });
      document.body.append(a); a.click(); a.remove();
      toast('Your browser blocked the preview window, so the file was downloaded instead. Open it to print.', '', 6000);
    } else toast('Opened in a new window — use its print button.');
  } catch (e) { if (e.name !== 'AbortError') toast('Could not prepare: ' + e.message, 'error'); else hideToast(); }
}


/* ---------- Markdown ---------- */
const MD_EXT = /\.(md|markdown|mdown|mkd|mkdn|mdwn|mdtxt|mdtext|rmd)$/i;
const isMd = (f) => MD_EXT.test(f.name) || /^text\/(x-)?markdown$/.test(f.type);
const isPdf = (f) => /\.pdf$/i.test(f.name) || f.type === 'application/pdf';
const isImg = (f) => /^image\//.test(f.type) || /\.(png|jpe?g|gif|webp|svg|bmp|avif)$/i.test(f.name);
function hasDoc() { return S.pages.length > 0 || S.mode === 'md'; }
S.mode = null; S.md = null; S.mdZoom = store.get('mdZoom', 1);
const mdWrap = $('#mdWrap'), mdSource = $('#mdSource'), mdScroll = $('#mdScroll'), mdView = $('#mdView');
const mdParser = new marked.Marked({ gfm: true, breaks: false });
// Park relative image paths in data-src so the browser doesn't try to load them from the app's own folder.
DOMPurify.addHook('afterSanitizeAttributes', (node) => {
  if (node.tagName !== 'IMG') return;
  const src = node.getAttribute('src') || '';
  if (!/^(https?:|data:image\/|blob:)/i.test(src)) { node.setAttribute('data-src', src); node.removeAttribute('src'); }
});

// Open whatever the user picked: a Markdown file (plus any images it uses), or PDFs.
function openAny(files) {
  files = [...files];
  const md = files.find(isMd);
  const imgs = files.filter(isImg);
  if (md) return openMarkdown(md, imgs);
  if (S.mode === 'md' && imgs.length && !files.some(isPdf)) { addMdImages(imgs); return; }
  const pdfs = files.filter(isPdf);
  if (!pdfs.length) { toast('Please choose a PDF or Markdown (.md) file.', 'error'); return; }
  return openFiles(pdfs, 'replace');
}
function setMode(m) {
  S.mode = m;
  document.body.classList.toggle('mode-md', m === 'md');
  document.body.classList.toggle('mode-pdf', m === 'pdf');
  mdWrap.hidden = m !== 'md';
  pagesEl.hidden = m === 'md';
  showTab(m === 'md' ? 'outline' : 'thumbs');
  updateUI();
  updateZoomUI();
}
function leaveMarkdown() {
  if (!S.md) return;
  for (const u of S.md.images.values()) URL.revokeObjectURL(u);
  S.md = null;
  mdView.replaceChildren(); mdSource.value = ''; $('#outline').replaceChildren();
}
function leavePdf() {
  if (!S.pages.length && !S.sources.size) return;
  closeEditor(false);
  for (const s of S.sources.values()) { try { s.doc.destroy(); } catch {} }
  S.sources.clear(); textCache.clear();
  S.pages = []; S.undo = []; S.redo = []; S.sel = null; S.current = 0;
  buildPages(); buildFormPanel();
  setTool('read');
}
async function openMarkdown(file, imgs = []) {
  if (S.dirty && !confirm('You have unsaved changes. Discard them and open another file?')) return;
  let text;
  try { text = (await file.text()).replace(/^﻿/, ''); }
  catch { toast('Could not read that file.', 'error'); return; }
  leavePdf();
  leaveMarkdown();
  clearSearch(); $('#searchInput').value = '';
  S.md = { name: file.name, text, images: new Map(), view: 'preview' };
  for (const f of imgs) S.md.images.set(f.name.toLowerCase(), URL.createObjectURL(f));
  mdSource.value = text;
  setMode('md');
  applyMdZoom();
  setMdView('preview'); // Markdown always opens in the formatted preview
  mdScroll.scrollTop = 0; mdSource.scrollTop = 0; viewer.scrollTop = 0;
  setDirty(false);
}
function addMdImages(imgs) {
  for (const f of imgs) S.md.images.set(f.name.toLowerCase(), URL.createObjectURL(f));
  renderMd();
  toast(`Added ${imgs.length} image${imgs.length > 1 ? 's' : ''}`);
}
function setMdView(v) {
  if (!S.md) return;
  S.md.view = v;
  mdWrap.className = 'v-' + v;
  $$('.seg-btn').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.mdview === v)));
  if (v !== 'source') renderMd();
  if (v !== 'preview') setTimeout(() => mdSource.focus({ preventScroll: true }), 0);
}
$$('.seg-btn').forEach((b) => b.addEventListener('click', () => setMdView(b.dataset.mdview)));
function applyMdZoom() {
  mdWrap.style.setProperty('--md-zoom', String(S.mdZoom));
  store.set('mdZoom', S.mdZoom);
  updateZoomUI();
}
function slugify(t) {
  return t.toLowerCase().trim().replace(/[^\p{L}\p{N}\s_-]/gu, '').replace(/\s+/g, '-') || 'section';
}
function renderMd() {
  if (!S.md) return;
  const range = mdScroll.scrollHeight - mdScroll.clientHeight;
  const keep = range > 0 ? mdScroll.scrollTop / range : 0;
  let body = S.md.text, front = null;
  const fm = /^---[ \t]*\r?\n([\s\S]*?)\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/.exec(body);
  if (fm) { front = fm[1]; body = body.slice(fm[0].length); }
  let html;
  try { html = mdParser.parse(body); } catch (e) { console.error(e); html = ''; }
  // Markdown can contain raw HTML: remove scripts, event handlers, styles and form controls.
  mdView.innerHTML = DOMPurify.sanitize(html, {
    FORBID_TAGS: ['style', 'form', 'button', 'textarea', 'select'],
    FORBID_ATTR: ['style'],
  });
  if (front) mdView.prepend(el('details', { class: 'frontmatter' }, el('summary', {}, 'Document properties'), el('pre', {}, front)));
  // heading anchors (GitHub-style ids)
  const used = new Map();
  for (const h of mdView.querySelectorAll('h1,h2,h3,h4,h5,h6')) {
    const base = slugify(h.textContent);
    const n = used.get(base) || 0;
    used.set(base, n + 1);
    h.id = n ? `${base}-${n}` : base;
  }
  // links: web links open in the browser; #links jump within the document
  for (const a of mdView.querySelectorAll('a[href]')) {
    const href = a.getAttribute('href');
    if (/^(https?:|mailto:|tel:)/i.test(href)) { a.target = '_blank'; a.rel = 'noopener noreferrer'; }
    else if (href.startsWith('#')) { try { a.dataset.anchor = decodeURIComponent(href.slice(1)); } catch { a.dataset.anchor = href.slice(1); } }
    else a.dataset.local = href;
  }
  // pictures with relative paths: use image files the user opened together with the .md
  for (const img of mdView.querySelectorAll('img')) {
    if (img.dataset.src == null) continue;
    const src = img.dataset.src;
    let name = src.split(/[?#]/)[0].split(/[\\/]/).pop() || '';
    try { name = decodeURIComponent(name); } catch {}
    const url = S.md.images.get(name.toLowerCase());
    if (url) img.src = url;
    else img.replaceWith(el('span', { class: 'img-missing', title: 'Open or drop the image file together with the Markdown file to show it' }, `\u{1F5BC} ${img.alt || name || 'image'} (picture not loaded)`));
  }
  // wide tables scroll sideways
  for (const t of mdView.querySelectorAll('table')) { const w = el('div', { class: 'table-wrap' }); t.replaceWith(w); w.append(t); }
  // code highlighting
  for (const code of mdView.querySelectorAll('pre code')) {
    const lang = ([...code.classList].find((c) => c.startsWith('language-')) || '').slice(9);
    try {
      if (lang && hljs.getLanguage(lang)) hljs.highlightElement(code);
      else if (!lang && code.textContent.length < 5000) {
        const r = hljs.highlightAuto(code.textContent);
        if (r.relevance > 5) { code.innerHTML = r.value; code.classList.add('hljs'); }
      }
    } catch {}
  }
  if (S.search.q) { S.search.hits = []; S.search.cur = -1; $('#searchCount').textContent = ''; }
  buildOutline();
  const words = (body.match(/[\p{L}\p{N}]+/gu) || []).length;
  $('#mdStats').textContent = `${words.toLocaleString()} words · ${Math.max(1, Math.round(words / 230))} min read`;
  if (keep) mdScroll.scrollTop = keep * (mdScroll.scrollHeight - mdScroll.clientHeight);
}
function buildOutline() {
  const host = $('#outline');
  const hs = [...mdView.querySelectorAll('h1,h2,h3,h4')];
  if (!hs.length) { host.replaceChildren(el('div', { class: 'form-empty' }, 'No headings in this document.')); return; }
  host.replaceChildren(...hs.map((h) => {
    const b = el('button', { class: 'ol-item l' + h.tagName[1], 'data-id': h.id, title: h.textContent }, h.textContent);
    b.addEventListener('click', () => {
      if (S.md.view === 'source') setMdView('preview');
      h.scrollIntoView({ block: 'start', behavior: 'smooth' });
    });
    return b;
  }));
  markOutline();
}
function markOutline() {
  const items = $$('.ol-item');
  if (!items.length) return;
  const top = mdScroll.getBoundingClientRect().top + 40;
  let cur = items[0].dataset.id;
  for (const h of mdView.querySelectorAll('h1,h2,h3,h4')) { if (h.getBoundingClientRect().top <= top) cur = h.id; else break; }
  for (const b of items) b.classList.toggle('active', b.dataset.id === cur);
}
let olRaf = 0;
mdScroll.addEventListener('scroll', () => { if (!olRaf) olRaf = requestAnimationFrame(() => { olRaf = 0; markOutline(); }); });
mdView.addEventListener('click', (e) => {
  const a = e.target.closest('a');
  if (!a) return;
  if (a.dataset.anchor != null) {
    e.preventDefault();
    const id = a.dataset.anchor;
    const t = document.getElementById(id) || document.getElementById(slugify(id));
    if (t && mdView.contains(t)) t.scrollIntoView({ block: 'start', behavior: 'smooth' });
  } else if (a.dataset.local != null) {
    e.preventDefault();
    toast(`“${a.dataset.local}” is a separate file. Use Open to view it.`, '', 4000);
  }
});
// editing (Split / Source views)
let mdRenderT;
mdSource.addEventListener('input', () => {
  if (!S.md) return;
  S.md.text = mdSource.value;
  if (!S.dirty) setDirty(true);
  clearTimeout(mdRenderT);
  if (S.md.view === 'split') mdRenderT = setTimeout(renderMd, 150);
});
mdSource.addEventListener('keydown', (e) => {
  if (e.key === 'Tab' && !e.shiftKey && !e.ctrlKey && !e.metaKey && !e.altKey) {
    e.preventDefault();
    mdSource.setRangeText('  ', mdSource.selectionStart, mdSource.selectionEnd, 'end');
    mdSource.dispatchEvent(new Event('input'));
  }
});
mdSource.addEventListener('scroll', () => {
  if (!S.md || S.md.view !== 'split') return;
  const r = mdSource.scrollTop / Math.max(1, mdSource.scrollHeight - mdSource.clientHeight);
  mdScroll.scrollTop = r * (mdScroll.scrollHeight - mdScroll.clientHeight);
});
// find in the Markdown preview
function clearMdMarks() {
  const marks = mdView.querySelectorAll('mark.find');
  if (!marks.length) return;
  for (const m of marks) m.replaceWith(document.createTextNode(m.textContent));
  mdView.normalize();
}
function mdFind(q) {
  clearMdMarks();
  S.search.q = q; S.search.hits = []; S.search.cur = -1;
  if (!q.trim()) { $('#searchCount').textContent = ''; return; }
  if (S.md.view === 'source') setMdView('preview');
  const needle = q.toLowerCase();
  const walker = document.createTreeWalker(mdView, NodeFilter.SHOW_TEXT);
  const nodes = [];
  while (walker.nextNode()) nodes.push(walker.currentNode);
  const hits = [];
  for (const node of nodes) {
    const low = node.data.toLowerCase();
    const idx = [];
    for (let i = low.indexOf(needle); i !== -1; i = low.indexOf(needle, i + needle.length)) idx.push(i);
    const marks = [];
    for (let k = idx.length - 1; k >= 0; k--) { // wrap from the end so earlier offsets stay valid
      const r = document.createRange();
      r.setStart(node, idx[k]); r.setEnd(node, idx[k] + needle.length);
      const m = el('mark', { class: 'find' });
      r.surroundContents(m);
      marks.unshift(m);
    }
    hits.push(...marks);
  }
  S.search.hits = hits;
  if (!hits.length) { $('#searchCount').textContent = '0/0'; return; }
  mdGoto(0);
}
function mdGoto(i) {
  const hits = S.search.hits;
  if (!hits.length) return;
  if (hits[S.search.cur]) hits[S.search.cur].classList.remove('cur');
  S.search.cur = (i + hits.length) % hits.length;
  const m = hits[S.search.cur];
  m.classList.add('cur');
  m.scrollIntoView({ block: 'center' });
  $('#searchCount').textContent = `${S.search.cur + 1}/${hits.length}`;
}
function printMd() {
  if (!S.md) return;
  clearMdMarks(); $('#searchCount').textContent = '';
  if (S.md.view === 'source') setMdView('preview'); else renderMd();
  setTimeout(() => window.print(), 50);
}
$('#btnMdPrint').addEventListener('click', printMd);

/* ---------- UI wiring ---------- */
function updatePageUI() {
  $('#pageNum').value = S.pages.length ? String(S.current + 1) : '';
  $('#pageCount').textContent = '/ ' + S.pages.length;
  for (const [id, t] of thumbs) t.el.classList.toggle('current', S.pages[S.current] && S.pages[S.current].id === id);
  const cur = S.pages[S.current] && thumbs.get(S.pages[S.current].id);
  if (cur) {
    const host = $('#thumbs'), r = cur.el.getBoundingClientRect(), hr = host.getBoundingClientRect();
    if (r.top < hr.top || r.bottom > hr.bottom) cur.el.scrollIntoView({ block: 'nearest' });
  }
  $('#btnMoveUp').disabled = S.current <= 0;
  $('#btnMoveDown').disabled = S.current >= S.pages.length - 1;
  $('#btnDelPage').disabled = S.pages.length <= 1;
}
function updateUI() {
  const has = hasDoc();
  document.body.classList.toggle('no-doc', !has);
  $('#empty').hidden = has;
  $('#btnUndo').disabled = !S.undo.length;
  $('#btnRedo').disabled = !S.redo.length;
  updatePageUI();
  updateProps();
  setDirty(S.dirty);
}
$('#btnOpen').addEventListener('click', () => $('#fileOpen').click());
$('#btnOpen2').addEventListener('click', () => $('#fileOpen').click());
$('#btnAdd').addEventListener('click', () => $('#fileAdd').click());
$('#fileOpen').addEventListener('change', (e) => { const f = [...e.target.files]; e.target.value = ''; if (f.length) openAny(f); });
$('#fileAdd').addEventListener('change', (e) => { const f = [...e.target.files]; e.target.value = ''; if (f.length) openFiles(f, 'append'); });
$('#btnSave').addEventListener('click', save);
$('#btnPrint').addEventListener('click', printDoc);
$('#btnUndo').addEventListener('click', undo);
$('#btnRedo').addEventListener('click', redo);
$('#btnZoomIn').addEventListener('click', () => zoomStep(1));
$('#btnZoomOut').addEventListener('click', () => zoomStep(-1));
$('#zoomSel').addEventListener('change', (e) => {
  const v = e.target.value;
  if (S.mode === 'md') { setZoom(v === 'fitw' || v === 'fitp' ? 1 : parseFloat(v) || 1); return; }
  if (v === 'fitw' || v === 'fitp') { S.zoomMode = v; applyZoom(); }
  else if (v !== 'custom') setZoom(parseFloat(v));
});
$('#pageNum').addEventListener('change', (e) => {
  const n = parseInt(e.target.value, 10);
  if (n >= 1 && n <= S.pages.length) scrollToIndex(n - 1); else updatePageUI();
});
$('#pageNum').addEventListener('keydown', (e) => { if (e.key === 'Enter') e.target.blur(); });
$('#btnSidebar').addEventListener('click', () => {
  $('#sidebar').classList.toggle('collapsed');
  store.set('sidebar', !$('#sidebar').classList.contains('collapsed'));
  if (S.zoomMode !== 'custom' && S.pages.length) applyZoom();
});
if (store.get('sidebar', true) === false) $('#sidebar').classList.add('collapsed');
$('#btnHelp').addEventListener('click', () => $('#helpDlg').showModal());

// keyboard shortcuts
document.addEventListener('keydown', (e) => {
  const mod = isMac ? e.metaKey : e.ctrlKey;
  const k = e.key.toLowerCase();
  const inField = /^(input|textarea|select)$/i.test(document.activeElement?.tagName || '') || document.querySelector('dialog[open]');
  if (mod && k === 'o') { e.preventDefault(); $('#fileOpen').click(); return; }
  if (mod && k === 's') { e.preventDefault(); save(); return; }
  if (mod && k === 'p' && hasDoc()) { e.preventDefault(); printDoc(); return; }
  if (mod && k === 'e' && S.mode === 'md') { e.preventDefault(); setMdView(S.md.view === 'preview' ? 'split' : 'preview'); return; }
  if (mod && k === 'f' && hasDoc()) { e.preventDefault(); $('#searchInput').focus(); $('#searchInput').select(); return; }
  if (inField) return;
  if (mod && k === 'z' && !e.shiftKey) { e.preventDefault(); undo(); return; }
  if (mod && (k === 'y' || (k === 'z' && e.shiftKey))) { e.preventDefault(); redo(); return; }
  if (mod && (k === '=' || k === '+')) { e.preventDefault(); zoomStep(1); return; }
  if (mod && k === '-') { e.preventDefault(); zoomStep(-1); return; }
  if (mod && k === '0') { e.preventDefault(); setZoom(1); return; }
  if (mod || e.altKey || !S.pages.length) return;
  if ((k === 'delete' || k === 'backspace') && S.sel) { e.preventDefault(); deleteSelected(); return; }
  if (k === 'escape') { if (S.sel) select(null); else if (S.tool !== 'read') setTool('read'); return; }
  if (S.sel && k.startsWith('arrow')) {
    e.preventDefault();
    const p = pageById(S.sel.pid), a = findAnnot(p, S.sel.aid); if (!a) return;
    const vp = vpFor(p), step = e.shiftKey ? 10 : 1;
    const dx = k === 'arrowleft' ? -step : k === 'arrowright' ? step : 0, dy = k === 'arrowup' ? -step : k === 'arrowdown' ? step : 0;
    const [x0, y0] = vp.convertToPdfPoint(0, 0), [x1, y1] = vp.convertToPdfPoint(dx, dy);
    pushUndo();
    moveAnnot(a, structuredClone(a), x1 - x0, y1 - y0);
    drawOverlay(p); scheduleThumb(p);
    return;
  }
  const map = { v: 'read', s: 'select', t: 'text', d: 'ink', h: 'highlight', r: 'rect', w: 'whiteout' };
  if (map[k]) { setTool(map[k]); return; }
  if (k === 'pagedown' || k === 'pageup' || k === 'home' || k === 'end') viewer.focus();
});

// drag & drop files
let dragDepth = 0;
const hasFiles = (e) => [...(e.dataTransfer?.types || [])].includes('Files');
window.addEventListener('dragenter', (e) => { if (!hasFiles(e)) return; e.preventDefault(); dragDepth++; document.body.classList.add('dragging-file'); });
window.addEventListener('dragleave', (e) => { if (!hasFiles(e)) return; dragDepth = Math.max(0, dragDepth - 1); if (!dragDepth) document.body.classList.remove('dragging-file'); });
window.addEventListener('dragover', (e) => { if (hasFiles(e)) e.preventDefault(); });
window.addEventListener('drop', (e) => {
  if (!hasFiles(e)) return;
  e.preventDefault(); dragDepth = 0; document.body.classList.remove('dragging-file');
  const files = [...e.dataTransfer.files];
  const imgs = files.filter((f) => /^image\//.test(f.type));
  if (files.some(isMd) || S.mode === 'md') { openAny(files); return; }
  if (imgs.length && S.pages.length) { addImageFromBlob(imgs[0], 'img').then((id) => placeImage(id, 200)).catch((err) => toast(err.message, 'error')); return; }
  openFiles(files, S.pages.length ? 'append' : 'replace');
});

// test hooks (used by automated checks; harmless otherwise)
window.__pdfstudio = { S, exportPdf, openFiles, openAny, setTool, fontsReady };

setTool('read');
updateUI();
})();
```

### 9.6 `tools/icon-maker.html`
Draws the logo with the canvas `Path2D` API and saves PNG images packed into:
- **`.ico`**: a 6-byte header, a 16-byte entry per size, then the PNG data.
- **`.icns`**: `icns` plus the total length, then chunks named `ic07` (128 px) through `ic14` and `icp4` through `icp6`, each holding a PNG.

**File: `tools/icon-maker.html`**

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>PDF Studio icon maker</title>
<style>
  body { font: 15px/1.5 system-ui, sans-serif; max-width: 640px; margin: 40px auto; padding: 0 16px; color: #1f2328; }
  button { font: inherit; padding: 8px 14px; border-radius: 8px; border: 1px solid #ccc; background: #fff; cursor: pointer; margin: 4px 6px 4px 0; }
  button.primary { background: #d6402b; color: #fff; border-color: #d6402b; }
  #preview canvas { margin: 8px 8px 0 0; vertical-align: bottom; }
</style>
</head>
<body>
<h1>PDF Studio icon maker</h1>
<p>Makes the app icons on this computer. Click the buttons, then move the downloaded files into the project's <code>assets</code> folder.</p>
<div id="preview"></div>
<p>
  <button class="primary" id="ico">Download pdf-studio.ico (Windows)</button>
  <button class="primary" id="icns">Download PDFStudio.icns (Mac)</button>
</p>
<script>
// Logo drawn on a 64x64 grid with SVG path strings.
const LOGO = [
  { d: 'M18 4h28a14 14 0 0 1 14 14v28a14 14 0 0 1-14 14H18A14 14 0 0 1 4 46V18A14 14 0 0 1 18 4z', fill: '#d6402b' },
  { d: 'M22 14h14l10 10v24a3 3 0 0 1-3 3H22a3 3 0 0 1-3-3V17a3 3 0 0 1 3-3z', fill: '#ffffff' },
  { d: 'M36 14v10h10z', fill: '#f6c3ba' },
  { d: 'M25 41c4-4 5-12 8-12s1 9 4 9 3-3 5-3', stroke: '#d6402b', width: 2.6 },
];
function draw(size) {
  const c = document.createElement('canvas');
  c.width = c.height = size;
  const ctx = c.getContext('2d');
  ctx.scale(size / 64, size / 64);
  ctx.lineCap = 'round'; ctx.lineJoin = 'round';
  for (const p of LOGO) {
    const path = new Path2D(p.d);
    if (p.fill) { ctx.fillStyle = p.fill; ctx.fill(path); }
    if (p.stroke) { ctx.strokeStyle = p.stroke; ctx.lineWidth = p.width; ctx.stroke(path); }
  }
  return c;
}
const pngBytes = (size) => new Promise((res) => draw(size).toBlob(async (b) => res(new Uint8Array(await b.arrayBuffer())), 'image/png'));

// Windows .ico: a small header followed by PNG images.
async function makeIco() {
  const sizes = [16, 24, 32, 48, 64, 128, 256];
  const imgs = await Promise.all(sizes.map(pngBytes));
  const head = 6 + 16 * sizes.length;
  const total = head + imgs.reduce((n, b) => n + b.length, 0);
  const out = new Uint8Array(total), dv = new DataView(out.buffer);
  dv.setUint16(2, 1, true); dv.setUint16(4, sizes.length, true);
  let off = head;
  sizes.forEach((s, i) => {
    const e = 6 + 16 * i;
    out[e] = s >= 256 ? 0 : s; out[e + 1] = s >= 256 ? 0 : s;
    dv.setUint16(e + 4, 1, true); dv.setUint16(e + 6, 32, true);
    dv.setUint32(e + 8, imgs[i].length, true); dv.setUint32(e + 12, off, true);
    out.set(imgs[i], off); off += imgs[i].length;
  });
  return out;
}
// macOS .icns: "icns" + length, then typed PNG chunks.
async function makeIcns() {
  const types = [['icp4', 16], ['icp5', 32], ['icp6', 64], ['ic07', 128], ['ic08', 256], ['ic09', 512], ['ic10', 1024], ['ic11', 32], ['ic12', 64], ['ic13', 256], ['ic14', 512]];
  const imgs = await Promise.all(types.map(([, s]) => pngBytes(s)));
  const total = 8 + imgs.reduce((n, b) => n + 8 + b.length, 0);
  const out = new Uint8Array(total), dv = new DataView(out.buffer);
  const tag = (o, t) => { for (let i = 0; i < 4; i++) out[o + i] = t.charCodeAt(i); };
  tag(0, 'icns'); dv.setUint32(4, total);
  let off = 8;
  types.forEach(([t], i) => {
    tag(off, t); dv.setUint32(off + 4, 8 + imgs[i].length);
    out.set(imgs[i], off + 8); off += 8 + imgs[i].length;
  });
  return out;
}
function download(bytes, name) {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([bytes]));
  a.download = name;
  document.body.append(a); a.click(); a.remove();
}
document.getElementById('ico').onclick = async () => download(await makeIco(), 'pdf-studio.ico');
document.getElementById('icns').onclick = async () => download(await makeIcns(), 'PDFStudio.icns');
for (const s of [16, 32, 64, 128]) document.getElementById('preview').append(draw(s));
</script>
</body>
</html>
```

### 9.7 Installers
- **`Install on Windows.bat`**: the double-clickable starter. It runs the PowerShell script with `-ExecutionPolicy Bypass`, which applies only to this one run and needs no admin.
- **`windows-install.ps1`** does the work:
  - copies the app to `%LOCALAPPDATA%\PDF Studio`;
  - finds Edge, Chrome or Brave (registry "App Paths", then the usual folders);
  - creates `.lnk` shortcuts that run `msedge.exe --app="file:///…/PDF-Studio.html"` (if no browser is found, the shortcut opens the HTML in the default browser);
  - launches the app.
- **`Uninstall on Windows.bat`**: removes the shortcuts and the folder. It first moves to `%TEMP%` so it doesn't lock its own folder.
- **`Install on Mac.command`**: builds a minimal `.app` bundle in `~/Applications`. This is an `Info.plist` plus a small shell script as the program, which opens Chrome, Edge or Brave with `--app=file://…`, or Safari as a fallback. It also clears download flags (`xattr -cr`) and registers the icon (`lsregister`).
- **`Uninstall on Mac.command`**: deletes the `.app`.

**File: `installers/Install on Windows.bat`**

```bat
@echo off
title PDF Studio - Install
echo.
echo  Installing PDF Studio for %USERNAME% (no administrator rights needed)...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows-install.ps1"
if errorlevel 1 (
  echo.
  echo  Installation did not finish. You can still use PDF Studio by
  echo  double-clicking app\PDF-Studio.html in this folder.
)
echo.
pause
```

**File: `installers/windows-install.ps1`**

```powershell
# PDF Studio - per-user installer for Windows. Needs no admin rights:
# everything goes into %LOCALAPPDATA%, the Start Menu and the Desktop of the current user.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dest = Join-Path $env:LOCALAPPDATA 'PDF Studio'

New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item (Join-Path $here 'app\PDF-Studio.html') $dest -Force
$iconSrc = Join-Path $here 'app\pdf-studio.ico'
if (Test-Path $iconSrc) { Copy-Item $iconSrc $dest -Force }
Copy-Item (Join-Path $here 'Uninstall on Windows.bat') (Join-Path $dest 'Uninstall PDF Studio.bat') -Force
Get-ChildItem $dest | Unblock-File -ErrorAction SilentlyContinue

function Find-Browser {
  foreach ($exe in 'msedge.exe', 'chrome.exe', 'brave.exe') {
    foreach ($root in 'HKCU:', 'HKLM:') {
      try {
        $v = (Get-ItemProperty -Path "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$exe" -ErrorAction Stop).'(default)'
        if ($v) { $v = $v.Trim('"'); if (Test-Path $v) { return $v } }
      } catch {}
    }
  }
  $paths = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
  )
  foreach ($p in $paths) { if ($p -and (Test-Path $p)) { return $p } }
  return $null
}

$html = Join-Path $dest 'PDF-Studio.html'
$url = ([System.Uri]$html).AbsoluteUri
$browser = Find-Browser
$iconFile = Join-Path $dest 'pdf-studio.ico'

function New-AppShortcut([string]$path) {
  $ws = New-Object -ComObject WScript.Shell
  $s = $ws.CreateShortcut($path)
  if ($browser) {
    $s.TargetPath = $browser
    $s.Arguments = "--app=`"$url`""
  } else {
    $s.TargetPath = $html
  }
  $s.WorkingDirectory = $dest
  if (Test-Path $iconFile) { $s.IconLocation = "$iconFile,0" }
  $s.Description = 'PDF Studio - read and edit PDF files'
  $s.Save()
}

$made = @()
foreach ($dir in @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop'))) {
  try {
    if ($dir) { $lnk = Join-Path $dir 'PDF Studio.lnk'; New-AppShortcut $lnk; $made += $lnk }
  } catch { Write-Host "  Could not create shortcut in $dir : $($_.Exception.Message)" }
}

Write-Host "  Installed to: $dest"
foreach ($m in $made) { Write-Host "  Shortcut:     $m" }
if ($browser) { Write-Host "  Opens in:     $browser (app window)" } else { Write-Host '  Opens in:     your default browser' }
Write-Host ''
Write-Host '  Done! Launching PDF Studio...'

if ($browser) { Start-Process -FilePath $browser -ArgumentList "--app=`"$url`"" } else { Start-Process $html }
```

**File: `installers/Uninstall on Windows.bat`**

```bat
@echo off
title PDF Studio - Uninstall
cd /d "%TEMP%"
echo Removing PDF Studio for %USERNAME%...
powershell -NoProfile -Command "Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path ([Environment]::GetFolderPath('Programs')) 'PDF Studio.lnk'), (Join-Path ([Environment]::GetFolderPath('Desktop')) 'PDF Studio.lnk')"
rem Delete the install folder last (this script may be running from inside it).
start "" /b cmd /c "timeout /t 1 >nul & rmdir /s /q "%LOCALAPPDATA%\PDF Studio""
echo PDF Studio has been removed.
pause
```

**File: `installers/Install on Mac.command`**

```bash
#!/bin/bash
# PDF Studio - per-user installer for macOS. Needs no admin password:
# the app is placed in ~/Applications (your own Applications folder).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/PDF Studio.app"

echo ""
echo "Installing PDF Studio to: $APP"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/app/PDF-Studio.html" "$APP/Contents/Resources/PDF-Studio.html"
[ -f "$HERE/app/PDFStudio.icns" ] && cp "$HERE/app/PDFStudio.icns" "$APP/Contents/Resources/PDFStudio.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PDF Studio</string>
  <key>CFBundleDisplayName</key><string>PDF Studio</string>
  <key>CFBundleIdentifier</key><string>local.pdfstudio.app</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>PDFStudio</string>
  <key>CFBundleIconFile</key><string>PDFStudio</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>10.13</string>
</dict>
</plist>
PLIST

cat > "$APP/Contents/MacOS/PDFStudio" <<'LAUNCH'
#!/bin/bash
# Opens PDF Studio in its own app window (Chrome/Edge/Brave), else the default browser.
RES="$(cd "$(dirname "$0")/../Resources" && pwd)"
HTML="$RES/PDF-Studio.html"
URL="file://$(printf '%s' "$HTML" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/#/%23/g' -e 's/?/%3F/g')"
for B in "Google Chrome" "Microsoft Edge" "Brave Browser" "Chromium" "Vivaldi"; do
  if open -Ra "$B" >/dev/null 2>&1; then
    exec open -na "$B" --args --app="$URL"
  fi
done
exec open "$HTML"
LAUNCH
chmod +x "$APP/Contents/MacOS/PDFStudio"

# Files made by this script are trusted; clear any download flags and refresh the icon.
xattr -cr "$APP" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
touch "$APP"

echo "Done! PDF Studio is in your Applications folder (Finder > Go > Home > Applications)."
echo "Tip: drag it to the Dock to keep it handy."
echo "Opening PDF Studio..."
open "$APP"
```

**File: `installers/Uninstall on Mac.command`**

```bash
#!/bin/bash
rm -rf "$HOME/Applications/PDF Studio.app"
echo "PDF Studio has been removed."
```

### 9.8 `README.md` (user instructions, copied next to the app)

**File: `README.md`**

```markdown
# PDF Studio

A PDF reader and editor, and a Markdown reader, that runs entirely on your computer. No admin rights, no account, no internet needed, and your files are never uploaded anywhere.

It works on Windows and macOS. It is one HTML file that opens in an app window of Chrome, Edge or Brave. If none of those is installed, it opens in your default browser (Safari works too).

## Install

### Windows (no admin needed)
1. Unzip `PDF-Studio.zip`. Right-click it, choose **Extract All…**, then open the extracted folder.
2. Double-click **`Install on Windows.bat`**.
   - If you see "Windows protected your PC", click **More info**, then **Run anyway**. This appears because the script isn't signed.
3. PDF Studio opens. You'll find it in the **Start menu** and on your **Desktop**.

It installs to `%LOCALAPPDATA%\PDF Studio`. To remove it, run `Uninstall PDF Studio.bat` in that folder.

### Mac (no admin password needed)
1. Double-click `PDF-Studio.zip` to unzip it.
2. Right-click **`Install on Mac.command`**, choose **Open**, then click **Open** again.
   - On macOS 15 (Sequoia) or later, double-click it once and close the warning. Then go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.
   - Or use Terminal instead: type `bash ` (with a space), drag the `.command` file into the Terminal window, and press Return.
3. PDF Studio opens. It's in your personal **Applications** folder (`~/Applications`). Drag it to the Dock to keep it handy.

To remove it, run `Uninstall on Mac.command`.

### No install at all
Double-click `app/PDF-Studio.html`. It opens in your browser and works the same.

## What it can do
| | |
|---|---|
| **Read** | Smooth scrolling, zoom (including Ctrl/⌘ + scroll and pinch), page thumbnails, find text, select and copy text |
| **Annotate** | Add text (fonts, sizes, colors), draw freehand, highlight, rectangles, white-out |
| **Sign** | Draw or type a signature. You can save signatures for reuse on this computer |
| **Images** | Insert PNG, JPG, WebP or GIF (drag and drop works). Move and resize them |
| **Forms** | Fill in fillable PDF forms (text boxes, checkboxes, radio buttons, dropdowns). Fields stay fillable after saving |
| **Pages** | Rotate, reorder (drag thumbnails), delete, insert blank pages, extract a range to a new PDF, merge PDFs |
| **Edit** | Select, move, resize and delete anything you added. Double-click text to edit it. Undo and redo everything |
| **Save / Print** | Saves a standard PDF that opens in any viewer. Print opens the edited PDF in your browser's viewer |
| **Markdown** | `.md` files open formatted (**Preview**) by default: headings, tables, task lists, code with syntax colors, quotes, links and images. An **Outline** of headings sits in the sidebar. Switch to **Split** (edit with live preview) or **Source** to edit, then save. **Print / Save as PDF** turns the document into a PDF |

### Keyboard shortcuts
`Ctrl/⌘ O` open · `Ctrl/⌘ S` save · `Ctrl/⌘ Z` / `Ctrl/⌘ Y` undo / redo · `Ctrl/⌘ F` find · `Ctrl/⌘ +/−` zoom ·
`Ctrl/⌘ E` switch a Markdown file between Preview and Split ·
`V` read · `S` select · `T` text · `D` draw · `H` highlight · `R` rectangle · `W` white-out · `Delete` remove selected · `Esc` done

## Limitations
- **Changing the PDF's own printed text:** PDFs don't store editable paragraphs. To change printed text, cover it with **White-out** and type new text on top.
- **White-out is not redaction.** It hides content visually, but the original text is still in the file. Don't use it to remove confidential information.
- **Characters:** Added text uses the standard PDF fonts (Helvetica, Times, Courier). These cover Western European characters. Other scripts and emoji are replaced with `?`.
- **Password-protected PDFs:** they open (you'll be asked for the password). When you save, protected pages are stored as high-quality images.
- **Markdown pictures:** pictures stored next to a `.md` file (like `images/chart.png`) appear only if you select or drop them together with the `.md` file. Web pictures (`https://…`) load normally.
- **Markdown safety:** HTML inside Markdown files is cleaned, so scripts and hidden form tricks can't run. Mermaid diagrams and math formulas show as plain code.
- **Saving:** Chrome and Edge show a "Save as" dialog. Safari saves to your Downloads folder.

## For developers
- You only need Node.js. Run `npm install` once, then `npm run build`. The app is written to `dist/PDF-Studio/`.
- `src/` holds the app (`index.html`, `app.css`, `app.js`). `build.mjs` takes the libraries from `node_modules` and inlines everything into one HTML file.
- Libraries: [PDF.js](https://mozilla.github.io/pdf.js/) 3.11.174 (Apache-2.0), [pdf-lib](https://pdf-lib.js.org/) 1.17.1 (MIT), [marked](https://marked.js.org/) 12.0.2 (MIT), [DOMPurify](https://github.com/cure53/DOMPurify) 3.1.6 (Apache-2.0/MPL-2.0), [highlight.js](https://highlightjs.org/) 11.9.0 (BSD-3-Clause).
- `tools/icon-maker.html` makes the Windows and Mac icon files in your browser.
- PDF.js runs with `isEvalSupported: false`, which turns off the font code path behind CVE-2024-4367.
```

---

## 10. Customizing and extending

| I want to… | Change this |
|---|---|
| Change the main color | `--accent` and `--accent-hover` in `src/app.css`, in both the light block and the dark block |
| Change default tool colors and sizes | `DEFAULT_DEFS` in `src/app.js` |
| Change the color swatches | `SWATCH` in `src/app.js` |
| Rename the app | `<title>` and `<h1>` in `index.html`, `document.title` in `setDirty()`, and the names in the installers |
| Change keyboard shortcuts | The `keydown` handler at the end of `app.js` (`const map = { v: 'read', … }`) |
| Change Markdown options | `new marked.Marked({ gfm: true, breaks: false })`. Set `breaks: true` to make single line breaks count |
| Allow more HTML in Markdown | The `DOMPurify.sanitize(...)` options in `renderMd()`. Be careful: this is the safety filter |

**Adding a new edit type** (for example, an arrow):
1. Add a button in `index.html`: `<button class="btn tool needs-doc" data-tool="arrow" …>`.
2. Add defaults to `DEFAULT_DEFS` (`arrow: { color: '#d6402b', width: 2 }`).
3. In the `pointerdown` handler, start a drag like the `'rect'` case and store `{ type: 'arrow', p1, p2, … }`.
4. Draw it on screen in `drawAnnot()` and in the saved PDF in `drawAnnotsLib()`, using `pg.drawLine` plus two short lines for the head.
5. Support selection in `annotPdfPoints()`, which feeds `bboxView()` and `hitTest()`, and moving in `moveAnnot()`.
6. Run `npm run build`.

**Custom fonts in added text.** The app uses the 14 standard PDF fonts, which need no embedding. To support other alphabets, add the `@pdf-lib/fontkit` package, call `out.registerFontkit(fontkit)`, and embed a `.ttf` with `out.embedFont(bytes)`. The editor would also need the same font for on-screen drawing.

---

## 11. Updating the libraries

- **pdf-lib, marked, DOMPurify, highlight.js:** change the version in `package.json`, run `npm install --omit=optional`, rebuild, and run through the test checklist. marked occasionally changes its API between major versions.
- **PDF.js 4 or later** needs code changes:
  1. Its files are ES modules (`pdf.min.mjs`), so they must be loaded as `<script type="module">`, and the worker must be created with `new Worker(url, { type: 'module' })`.
  2. Text layer drawing moved to the `TextLayer` class.
  3. `PageViewport` is exported directly, so the `.constructor` trick in `loadSource` becomes unnecessary.

  Plan time for testing if you do this.

---

## 12. Troubleshooting

| Problem | Fix |
|---|---|
| `node` or `npm` "not recognized" | Open a **new** terminal after editing PATH. Check that `node.exe` sits directly in the folder you added |
| PowerShell: "running scripts is disabled" | Use Command Prompt, or `npm.cmd`, or `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
| `npm install` fails behind a company proxy | `npm config set proxy http://proxy:port` and `npm config set https-proxy http://proxy:port`, or use the offline option in 2.4 |
| Build says `Missing pdfjs-dist/...` | Run `npm install --omit=optional` in the project folder, or fill `vendor/` (2.4) |
| `extract.mjs` writes 0 files | The guide was saved with changed formatting. Save it as plain text with the `.md` extension, don't copy from a rendered web page |
| Blank page, or pages never appear | Press **F12** → Console and read the first red error. Rebuild with `npm run build`. Make sure you're opening the file from `dist/PDF-Studio/app/` |
| Very slow pages; console says "Setting up fake worker" | The background worker didn't start. Check that `src/index.html` still has the `pdfjs-worker-src` script tag and that `app.js` sets `workerPort` |
| Windows: "Windows protected your PC" | **More info → Run anyway** (unsigned script) |
| Windows: installer closes with an error | Company policy may block PowerShell. Use the app without installing: double-click `app\PDF-Studio.html`, then pin your browser tab or create a shortcut by hand |
| Mac: "can't be opened" / "unidentified developer" | Run `bash "Install on Mac.command"` in Terminal, or use System Settings → Privacy & Security → **Open Anyway** |
| Mac: "permission denied" for `.command` | `chmod +x *.command`, or run it with `bash` |
| Saving goes straight to Downloads | That's how Safari and Firefox work. Chrome and Edge show a "Save as" window |
| Text I added shows `?` | The standard PDF fonts only cover Western European characters (see section 10) |
| Markdown pictures don't show | Select or drop the image files **together with** the `.md` file. Web pictures load normally |

---

## 13. Security and privacy notes

- **Offline and private.** The app makes no network requests of its own; your files never leave the computer. The only exception is pictures in a Markdown file that point to web addresses (`https://…`), which load like they would in any Markdown viewer.
- **PDF.js 3.11 and CVE-2024-4367.** That flaw lets a crafted PDF run code through the font loader's `eval` path. The app sets `isEvalSupported: false` when opening PDFs, which turns that path off. This is the mitigation the PDF.js team documented. `npm audit` still flags the version, which is expected.
- **PDF JavaScript and forms.** PDF scripts are never run. Form values are applied by pdf-lib when saving.
- **Markdown HTML.** Raw HTML in Markdown goes through DOMPurify. Scripts, `on…` event handlers, `javascript:` links, `<style>`, inline `style` and form controls are all removed.
- **White-out is not redaction.** It covers content visually, but the original text stays inside the PDF.
- **Signatures** you choose to remember are stored in the browser's local storage on this computer only.

---

## 14. Licenses

The libraries keep their own licenses: PDF.js Apache-2.0, pdf-lib MIT, marked MIT, DOMPurify Apache-2.0 or MPL-2.0, highlight.js BSD-3-Clause. The built HTML file contains their code, so if you share the app, include their license notices. You can find them in each package's folder in `node_modules` (`LICENSE` file).
