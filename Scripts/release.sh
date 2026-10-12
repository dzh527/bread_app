#!/usr/bin/env bash
#
# Archive CrumbScope and get it to App Store Connect.
#
#     Scripts/release.sh archive     # build build/CrumbScope.xcarchive
#     Scripts/release.sh export      # …then sign and write build/export/CrumbScope.ipa
#     Scripts/release.sh upload      # …then upload it for TestFlight / review
#
# Why the archive is built unsigned
# ---------------------------------
# Xcode's automatic signing wants an *iOS App Development* profile in order to
# archive, and a development profile requires at least one registered device.
# This team has none — no iPhone has ever been connected to this Mac — so signing
# at archive time fails with "Your team has no devices from which to generate a
# provisioning profile". Nothing is lost by skipping it: `-exportArchive` re-signs
# the app anyway, with an App Store profile, which needs no devices. The export
# has to be told the team explicitly, because an unsigned archive carries none.
#
# (To follow the normal path instead, connect an iPhone once — Xcode registers it,
# a development profile becomes possible, and CODE_SIGNING_ALLOWED=NO can go.)
#
# Credentials for `upload`
# ------------------------
# Either the Apple ID signed into Xcode, or an App Store Connect API key
# (App Store Connect → Users and Access → Integrations → App Store Connect API):
#
#     export ASC_KEY_PATH=~/AuthKey_ABC1234567.p8 \
#            ASC_KEY_ID=ABC1234567 ASC_ISSUER_ID=69a6de70-…
#
# Every upload needs a build number the store has not seen before: bump
# CURRENT_PROJECT_VERSION in the project first.
set -euo pipefail

cd "$(dirname "$0")/.."

ARCHIVE_PATH="build/CrumbScope.xcarchive"
EXPORT_PATH="build/export"
EXPORT_OPTIONS="build/ExportOptions.plist"
STEP="${1:-archive}"

# Read the team from the project so the two cannot drift apart.
TEAM_ID="${TEAM_ID:-$(sed -n 's/.*DEVELOPMENT_TEAM = \(.*\);/\1/p' CrumbScope.xcodeproj/project.pbxproj | head -1)}"
if [ -z "$TEAM_ID" ]; then
  echo "no DEVELOPMENT_TEAM found in CrumbScope.xcodeproj" >&2
  exit 1
fi

AUTH=()
if [ -n "${ASC_KEY_PATH:-}" ]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH"
        -authenticationKeyID "$ASC_KEY_ID"
        -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

# Every upload needs a build number the store has not seen, so `upload` bumps it
# first. The bump lands in the project file — commit it, or the repo stops
# matching what shipped. `archive` and `export` leave the number alone; they are
# local checks and bumping them would just create noise.
if [ "$STEP" = "upload" ]; then
  BEFORE=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \(.*\);/\1/p' CrumbScope.xcodeproj/project.pbxproj | head -1)
  xcrun agvtool next-version -all > /dev/null
  AFTER=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \(.*\);/\1/p' CrumbScope.xcodeproj/project.pbxproj | head -1)
  echo "==> build number $BEFORE -> $AFTER (commit CrumbScope.xcodeproj)"
fi

echo "==> archiving (unsigned — see the note at the top of this script)"
rm -rf "$ARCHIVE_PATH"
xcodebuild archive \
  -project CrumbScope.xcodeproj \
  -scheme CrumbScope \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGNING_ALLOWED=NO

if [ "$STEP" = "archive" ]; then
  echo "==> archived to $ARCHIVE_PATH"
  exit 0
fi

DESTINATION="export"
if [ "$STEP" = "upload" ]; then
  DESTINATION="upload"
fi

mkdir -p build
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>$DESTINATION</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST

echo "==> signing for team $TEAM_ID (destination: $DESTINATION)"
rm -rf "$EXPORT_PATH"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_PATH" \
  -allowProvisioningUpdates \
  ${AUTH[@]+"${AUTH[@]}"}

if [ "$STEP" = "upload" ]; then
  echo "==> uploaded — the build appears under TestFlight once Apple has processed it"
else
  echo "==> signed IPA at $EXPORT_PATH/CrumbScope.ipa"
fi
