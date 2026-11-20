#!/bin/bash
# Builds the native macOS app (a WebKit window around PDF-Studio.html) into dist/.
# Needs Xcode or the Xcode Command Line Tools (for swiftc). No admin password.
#   macos/build.sh [--debug] [path/to/PDF-Studio.html]
# The HTML defaults to dist/PDF-Studio/app/PDF-Studio.html from "npm run build".
# --debug builds "PDF Studio (Debug).app" with the automated-check hooks (see the end of PDFStudio.swift).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="PDF Studio"; BUNDLE_ID="local.pdfstudio.app"; FLAGS=(-O)
if [ "${1:-}" = "--debug" ]; then
  NAME="PDF Studio (Debug)"; BUNDLE_ID="local.pdfstudio.app.debug"; FLAGS=(-Onone -g -D DEBUG); shift
fi
HTML="${1:-$ROOT/dist/PDF-Studio/app/PDF-Studio.html}"
if [ ! -f "$HTML" ]; then
  echo "Missing $HTML. Run \"npm run build\" first, or pass the path to PDF-Studio.html." >&2
  exit 1
fi
VERSION="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$ROOT/package.json" | head -n 1)"
APP="$ROOT/dist/$NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc "${FLAGS[@]}" -parse-as-library -target "$(uname -m)-apple-macos12.0" \
  -o "$APP/Contents/MacOS/PDFStudio" "$ROOT/macos/PDFStudio.swift"
sed -e "s/__NAME__/$NAME/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__VERSION__/${VERSION:-1.0}/g" \
  "$ROOT/macos/Info.plist" > "$APP/Contents/Info.plist"
cp "$HTML" "$APP/Contents/Resources/PDF-Studio.html"
if [ -f "$ROOT/assets/PDFStudio.icns" ]; then cp "$ROOT/assets/PDFStudio.icns" "$APP/Contents/Resources/"; fi
# Sources unpacked from a download keep its quarantine flag, and cp copies it into the app.
# The app is built here, so clear those flags before signing.
xattr -cr "$APP"
# Ad-hoc signature: enough to run on this Mac. Sharing the app needs a Developer ID and notarization.
codesign --force --sign - "$APP"
echo "Built $APP"
