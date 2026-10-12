#!/usr/bin/env bash
#
# Captures the App Store screenshot set on a 6.9" simulator, headlessly.
#
#     Scripts/store-screenshots.sh [photo] [output directory] [grid, e.g. 4x6]
#
# The app is driven through the Debug-only `-demoImage` / `-demoAnalyze` launch
# arguments (see GridAnalysisViewModel), because `simctl` cannot synthesise touches
# and this machine has no Simulator GUI.
#
# Without a photo it renders the synthetic grid from Scripts/make_demo_grid.swift.
# That is good enough to prove the pipeline; it is NOT good enough to ship —
# regenerate with a real photo of a real bake before submitting.
set -euo pipefail

cd "$(dirname "$0")/.."

PHOTO="${1:-}"
OUT="${2:-.screenshots}"
GRID="${3:-4x6}"
DEVICE_NAME="CrumbScope Screenshots"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"
RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-3"
APP=".derivedData/Build/Products/Debug-iphonesimulator/CrumbScope.app"

if [ -z "$PHOTO" ]; then
  PHOTO="/tmp/demo_grid.png"
  if [ ! -f "$PHOTO" ]; then
    swift Scripts/make_demo_grid.swift "$PHOTO"
  fi
fi

mkdir -p "$OUT"

UDID=$(xcrun simctl list devices | grep -F "$DEVICE_NAME (" | grep -Eo '[0-9A-F-]{36}' | head -1 || true)
if [ -z "$UDID" ]; then
  UDID=$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$RUNTIME")
  echo "created simulator '$DEVICE_NAME' ($UDID)"
fi

xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

xcodebuild -project CrumbScope.xcodeproj -scheme CrumbScope \
  -destination "id=$UDID" -derivedDataPath .derivedData build \
  > /tmp/crumbscope_screenshots_build.log 2>&1
xcrun simctl install "$UDID" "$APP"

# Read the bundle id off the app that was just installed rather than repeating it
# here. It was hard-coded once, and when the project moved to a new bundle id the
# script kept installing the new build while launching the stale one.
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")

capture() {
  local name="$1" settle="$2"
  shift 2
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  sleep 1
  xcrun simctl launch "$UDID" "$BUNDLE_ID" "$@" >/dev/null
  sleep "$settle"
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png" >/dev/null 2>&1
  echo "  $OUT/$name.png  ($(sips -g pixelWidth "$OUT/$name.png" | tail -1 | awk '{print $2}') px wide)"
}

echo "capturing to $OUT — photo: $PHOTO"
capture 1-home     4
capture 2-preview  6 -demoImage "$PHOTO" -demoGrid "$GRID"
capture 3-analysis 30 -demoImage "$PHOTO" -demoGrid "$GRID" -demoAnalyze
capture 4-results  30 -demoImage "$PHOTO" -demoGrid "$GRID" -demoAnalyze -demoScrollToResults
echo "done"
