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
- `macos/` builds a native Mac app that needs no browser: a WebKit window around the same HTML, with Finder **Open With**, native Open/Save/Print dialogs and an unsaved-changes warning. It needs Xcode or the Command Line Tools. Run `macos/build.sh` (after `npm run build`, or pass the path to a built `PDF-Studio.html`), then `macos/install.sh` to put it in `~/Applications`. `macos/build.sh --debug` builds a separate test copy with the automated-check hooks described at the end of `macos/PDFStudio.swift`.
- `windows/` builds the same native app for Windows: a WebView2 (Edge engine) window around the same HTML, with document tabs (Ctrl+T, Ctrl+W, Ctrl+Tab, Ctrl+1–9), Explorer **Open with**, native Open/Save dialogs, a print preview window and an unsaved-changes warning. It compiles with the C# compiler built into Windows, so no Visual Studio, SDK or admin rights are needed; the build downloads Microsoft's WebView2 SDK from nuget.org once (checksum-pinned). Run `powershell -ExecutionPolicy Bypass -File windows\build.ps1` (after `npm run build`, or pass `-Html path\to\PDF-Studio.html`), then `Install PDF Studio.bat` in `dist\PDF-Studio-Windows`. Uninstall from **Settings → Apps → Installed apps**. `windows\build.ps1 -DebugBuild` builds a separate test copy with the developer tools on.
- `ios/` is a native iPhone and iPad app (SwiftUI + PDFKit) with the same features, plus Files-app integration. See `ios/README.md`.
- PDF.js runs with `isEvalSupported: false`, which turns off the font code path behind CVE-2024-4367.
