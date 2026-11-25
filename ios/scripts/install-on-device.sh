#!/bin/bash
# Builds PDF Studio and installs it on a paired iPhone/iPad (USB, or Wi-Fi once paired).
# Usage: ios/scripts/install-on-device.sh [device-name-or-udid]
# First time: connect the phone by cable, tap "Trust", and turn on
# Settings > Privacy & Security > Developer Mode (the phone restarts).
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null

DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
  DEVICE="$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin)["result"]["devices"]; r=[x for x in d if x.get("hardwareProperties",{}).get("reality")=="physical"]; print(r[0]["identifier"] if r else "")')"
fi
[ -n "$DEVICE" ] || { echo "No paired iPhone found. Connect it by cable, unlock it and tap Trust."; exit 1; }
UDID="$(xcrun devicectl device info details --device "$DEVICE" --json-output /dev/stdout 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["hardwareProperties"]["udid"])')"

xcodebuild -project PDFStudio.xcodeproj -scheme PDFStudio -configuration Release \
  -destination "platform=iOS,id=$UDID" -derivedDataPath build/device \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build | grep -E "error|warning: .*signing|BUILD" || true
APP="build/device/Build/Products/Release-iphoneos/PDFStudio.app"
[ -d "$APP" ] || { echo "Build failed."; exit 1; }
xcrun devicectl device install app --device "$DEVICE" "$APP"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" || true
echo "Installed on $DEVICE."
