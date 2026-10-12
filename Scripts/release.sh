#!/usr/bin/env bash
#
# Archive CrumbScope and, optionally, upload it to App Store Connect.
#
#     Scripts/release.sh archive     # build build/CrumbScope.xcarchive
#     Scripts/release.sh upload      # archive, then upload for TestFlight / review
#
# Signing is automatic, through whichever Apple ID is signed into Xcode
# (Xcode → Settings → Accounts). If the command-line session cannot authenticate
# the upload, use an App Store Connect API key instead — create one under
# App Store Connect → Users and Access → Integrations → App Store Connect API:
#
#     export ASC_KEY_PATH=~/AuthKey_ABC1234567.p8 \
#            ASC_KEY_ID=ABC1234567 ASC_ISSUER_ID=69a6de70-…
#
# Every upload needs a build number the store has not seen before: bump
# CURRENT_PROJECT_VERSION in the project before running.
set -euo pipefail

cd "$(dirname "$0")/.."

ARCHIVE_PATH="build/CrumbScope.xcarchive"
EXPORT_PATH="build/export"
EXPORT_OPTIONS="build/ExportOptions.plist"

# Bash 3.2 (the system bash) chokes on expanding an empty array under `set -u`,
# hence the ${AUTH[@]+…} form at every use below.
AUTH=()
if [ -n "${ASC_KEY_PATH:-}" ]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH"
        -authenticationKeyID "$ASC_KEY_ID"
        -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

echo "==> archiving"
xcodebuild archive \
  -project CrumbScope.xcodeproj \
  -scheme CrumbScope \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  ${AUTH[@]+"${AUTH[@]}"}

if [ "${1:-archive}" != "upload" ]; then
  echo "==> archived to $ARCHIVE_PATH — pass 'upload' to send it to App Store Connect"
  exit 0
fi

mkdir -p build
cat > "$EXPORT_OPTIONS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST

echo "==> uploading"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_PATH" \
  -allowProvisioningUpdates \
  ${AUTH[@]+"${AUTH[@]}"}

echo "==> uploaded — the build shows up under TestFlight once Apple has processed it"
