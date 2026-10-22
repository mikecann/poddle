#!/usr/bin/env bash
# Builds Poddle for the iOS Simulator, opens every screen directly with -PoddleScreen and saves a
# screenshot of each to designs/build-shots/. Compare them with designs/explore-poodle/fluff.jpg.
#
#   scripts/screenshots.sh                 # all screens, light
#   scripts/screenshots.sh upNext npSettings    # just these
#   SKIP_BUILD=1 scripts/screenshots.sh    # reuse the last build
#   APPEARANCE=dark scripts/screenshots.sh # warm dark mode (saved with a -dark suffix)
#   DEVICE="iPad Pro 13-inch (M5)" scripts/screenshots.sh
#   LIVE=1 scripts/screenshots.sh library  # real data from the Debug deployment, saved as live-*.png
#                                          # (launch the app once first so the cache is filled)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
DEVICE=${DEVICE:-"iPhone 17 Pro"}
OS=${OS:-27.0}
OUT=${OUT:-"$ROOT/designs/build-shots"}
DERIVED="$ROOT/build/DerivedData"
BUNDLE=com.mikecann.poddle
APPEARANCE=${APPEARANCE:-light}
WAIT=${WAIT:-3}

ALL=(upNext nowPlaying npNotes npSettings queue undoArchive podcast showSettings discover discoverEmpty importDone stats yearInReview library libraryList settings import episode upNextEmpty notFound sleepTimer signIn)
SCREENS=("$@")
[ ${#SCREENS[@]} -eq 0 ] && SCREENS=("${ALL[@]}")

# Find (or make) a simulator for this device and OS.
UDID=$(xcrun simctl list devices available -j | python3 -c "
import json, sys
d = json.load(sys.stdin)['devices']
for runtime, devs in d.items():
    if runtime.endswith('iOS-' + '$OS'.replace('.', '-')):
        for dev in devs:
            if dev['name'] == '$DEVICE':
                print(dev['udid']); sys.exit()
")
if [ -z "$UDID" ]; then
  TYPE=$(xcrun simctl list devicetypes -j | python3 -c "
import json, sys
for t in json.load(sys.stdin)['devicetypes']:
    if t['name'] == '$DEVICE': print(t['identifier'])
")
  UDID=$(xcrun simctl create "$DEVICE" "$TYPE" "com.apple.CoreSimulator.SimRuntime.iOS-${OS//./-}")
fi
echo "Simulator: $DEVICE ($OS) $UDID"

if [ -z "${SKIP_BUILD:-}" ]; then
  xcodebuild -project Poddle.xcodeproj -scheme Poddle -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" build -quiet
fi
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Poddle.app"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance "$APPEARANCE"
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 --dataNetwork wifi
xcrun simctl install "$UDID" "$APP"
mkdir -p "$OUT"

suffix=""
[ "$APPEARANCE" = "dark" ] && suffix="-dark"
prefix=""
DATA=(-PoddleMock YES)
if [ -n "${LIVE:-}" ]; then prefix="live-"; DATA=(-PoddleLive YES); fi
for screen in "${SCREENS[@]}"; do
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  xcrun simctl launch "$UDID" "$BUNDLE" "${DATA[@]}" -PoddleScreen "$screen" -PoddleAppearance "$APPEARANCE" >/dev/null
  wait=$WAIT
  case "$screen" in importDone) wait=$((WAIT + 5)) ;; esac
  sleep "$wait"
  xcrun simctl io "$UDID" screenshot --type=png "$OUT/$prefix$screen$suffix.png" >/dev/null 2>&1
  echo "  $OUT/$prefix$screen$suffix.png"
done
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
