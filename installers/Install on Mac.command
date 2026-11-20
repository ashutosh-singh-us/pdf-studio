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
