# PDF Studio for iPhone and iPad

A native iOS app (SwiftUI + PDFKit) with the same job as the desktop app: read and edit PDFs, and read and
edit Markdown. Free, no account, no ads, no tracking, no network access. Files never leave the device.

## Features
| | |
|---|---|
| **Files** | Opens PDFs and Markdown from the Files app, iCloud Drive, other providers and "Open in…" from any app's share sheet. Edits the file in place and saves automatically |
| **Read** | Smooth scrolling and pinch zoom, continuous, single and two-page layouts, page strip, Find (system find bar), text selection and copy, links |
| **Annotate** | Text boxes (size and colour), freehand drawing, highlight (drag across text, or an area), boxes, white-out. Select to move, resize, recolour or delete. Undo and redo everything |
| **Sign** | Draw or type a signature. Up to five saved on this device only |
| **Images** | From Photos or Files. Move and resize |
| **Forms** | Fill in fillable PDF forms; fields stay fillable |
| **Pages** | Rotate, reorder (drag), delete, insert blank pages, extract pages to a new PDF, add pages from other PDFs |
| **Share / Print** | Share or save a copy of the edited PDF, AirPrint |
| **Markdown** | Formatted preview (same renderer as desktop: GFM tables, task lists, code highlighting), Edit, and Split on iPad; outline, find, text size, export to PDF, print |

Saved PDFs are standard PDFs: text, drawings, highlights, boxes and form fields stay editable annotations
in other apps. Pictures and signatures are drawn into the page when saved.
White-out hides content visually; it is **not** redaction.

## Develop
Needs Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
```sh
cd ios
xcodegen                     # creates PDFStudio.xcodeproj from project.yml
open PDFStudio.xcodeproj
```
- App identity (bundle id, version) is in `Config/Signing.xcconfig`. Put your team id in
  `Config/Local.xcconfig` (not committed): `DEVELOPMENT_TEAM = XXXXXXXXXX`.
- The Markdown preview page `PDFStudio/Resources/markdown.html` is generated from the repo's npm packages:
  `npm install && node ios/scripts/build-markdown-renderer.mjs` (from the repo root). Rebuild it after
  changing `scripts/markdown-renderer.{js,css}` or library versions.
- Tests: unit tests cover saving, flattening, coordinates, page operations and undo; UI tests drive the
  PDF and Markdown editors and save screenshots:
  ```sh
  mkdir -p /tmp/seed /tmp/shots && cp ../README.md /tmp/seed/ && cupsfilter ../README.md > /tmp/seed/Sample.pdf
  TEST_RUNNER_SEED_DIR=/tmp/seed TEST_RUNNER_SCREENSHOT_DIR=/tmp/shots \
    xcodebuild -project PDFStudio.xcodeproj -scheme PDFStudio -destination 'platform=iOS Simulator,name=iPhone 17' test
  ```
  (Debug builds only: `PDFSTUDIO_OPEN_FILE` opens a file directly, bypassing the system document browser,
  which UI automation can't drive.)

## Install on your iPhone
1. Connect the iPhone by cable, unlock it, tap **Trust**.
2. On the iPhone: **Settings → Privacy & Security → Developer Mode → On** (it restarts).
3. `ios/scripts/install-on-device.sh`

After the first pairing it also works over Wi-Fi.

## TestFlight and the App Store
1. In [App Store Connect](https://appstoreconnect.apple.com) create the app (bundle id from `Config/Signing.xcconfig`).
2. Create an API key: **Users and Access → Integrations → App Store Connect API**, role *App Manager*.
   Save the `.p8` as `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8` (`chmod 600`).
3. `ASC_KEY_ID=… ASC_ISSUER_ID=… ios/scripts/testflight.sh`

## Opening files with PDF Studio
iOS has no "default app for PDFs" setting. The Files app always previews PDFs itself. PDF Studio
registers as an editor for PDF and Markdown, so it appears in **Share → PDF Studio** (or "Open in…") for any
PDF or `.md` file, and its own browser opens anything in Files, iCloud Drive and other providers.
Edits are saved back to the original file.

## Narrator (read aloud, on device)

Tap the headphones in a PDF to turn chapters into audio with Kokoro-82M, a small open voice model
that runs on the iPhone through MLX. Nothing leaves the device.

- **Setup:** the first PDF you open offers a one-time download of about 340 MB: the model, 18 English
  voices and the English pronunciation dictionary. Files come from pinned Hugging Face commits and are
  SHA-256 checked. A background URLSession keeps the download going if you leave the app. Everything is
  stored in Application Support/Narrator and excluded from iCloud backup.
- **Generate:** pick From/To chapters (for example 680 to 730), a narrator voice and a voice for quoted
  dialogue. With "Keep generating ahead" on, reaching chapter N while listening queues chapters up to
  N + 50.
- **Background:** iOS allows GPU work in the background only inside a continued-processing task
  (iOS 26+, devices that support background GPU). Generate starts one, shown as a Live Activity.
  Without it, generation pauses when you leave the app and resumes when you return. MLX on the CPU
  was measured far too slow to use as a fallback (no sentence finished in 90 s on an M4).
- **Storage:** AAC 32 kbps mono, about 0.27 MB per minute (about 250 MB for 50 chapters).
- **Playback:** lock screen and headphone controls, ±15 s, next/previous chapter, speed 0.8–2×.
  Your place is remembered per book.
- **Testing:** MLX doesn't run in the iOS simulator, so the end-to-end voice test runs only on a device.
- **Licences:** Kokoro-82M (Apache-2.0); mlx-audio-swift, mlx-swift and the Misaki/CMUdict
  pronunciation data (MIT); swift-huggingface (Apache-2.0).
