#!/bin/bash
# Archives a Release build and uploads it to App Store Connect (TestFlight).
# Needs an App Store Connect API key (Users and Access > Integrations > App Store Connect API, role: App Manager):
#   ASC_KEY_ID, ASC_ISSUER_ID in the environment, and the key file at
#   ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8   (chmod 600; never commit it)
# The build number is bumped automatically (CURRENT_PROJECT_VERSION = timestamp).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ASC_KEY_ID:?Set ASC_KEY_ID}"; : "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID}"
KEY="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
[ -f "$KEY" ] || { echo "Missing API key file: $KEY"; exit 1; }
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

xcodegen generate >/dev/null
BUILD="$(date -u +%Y%m%d%H%M)"
ARCHIVE="build/PDFStudio-$BUILD.xcarchive"
xcodebuild -project PDFStudio.xcodeproj -scheme PDFStudio -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD" "${AUTH[@]}" archive | grep -E "error|ARCHIVE" || true
[ -d "$ARCHIVE" ] || { echo "Archive failed."; exit 1; }

cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/export "${AUTH[@]}"
echo "Uploaded build $BUILD. It appears in App Store Connect > TestFlight after processing (usually 5-30 min)."
