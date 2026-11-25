#!/bin/bash
# Puts sample files into the app's Documents folder on a simulator (for manual and UI testing).
# Usage: ios/scripts/seed-simulator.sh [simulator-udid]   (default: booted)
set -euo pipefail
SIM="${1:-booted}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE_ID="$(sed -n 's/^APP_BUNDLE_ID = //p' "$ROOT/ios/Config/Signing.xcconfig")"
DOCS="$(xcrun simctl get_app_container "$SIM" "$BUNDLE_ID" data)/Documents"
mkdir -p "$DOCS"
cp "$ROOT/README.md" "$DOCS/README.md"
cupsfilter "$ROOT/README.md" > "$DOCS/Sample.pdf" 2>/dev/null
echo "Seeded $DOCS"
