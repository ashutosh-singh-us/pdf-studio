#!/bin/bash
# Installs the app built by macos/build.sh into ~/Applications. No admin password.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/dist/PDF Studio.app"
DEST="$HOME/Applications/PDF Studio.app"
if [ ! -d "$SRC" ]; then echo "Build it first: macos/build.sh" >&2; exit 1; fi
if pgrep -f "$DEST/Contents/MacOS/" >/dev/null; then echo "Quit PDF Studio first, then run this again." >&2; exit 1; fi
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
# Tell Finder about the app now, so it shows up under Open With straight away.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
echo "Installed $DEST"
