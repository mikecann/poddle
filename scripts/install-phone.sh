#!/bin/zsh
# Build Poddle (Release, prod deployment) and install it on Mike's iPhone over the cable.
# PUSH=0 (default until Xcode has an account) drops the push entitlement so the existing
# wildcard team profile can sign it. PUSH=1 needs automatic provisioning to work.
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE=${DEVICE:-00008020-000369202E90003A}   # MikeXS Max
DD=${DD:-/tmp/poddle-dd-device}
extra=()
[[ "${PUSH:-0}" == 1 ]] && extra+=(-allowProvisioningUpdates) || extra+=(CODE_SIGN_ENTITLEMENTS=)
[[ -f Config/Secrets.xcconfig ]] || scripts/write-secrets.sh
xcodebuild -project Poddle.xcodeproj -scheme Poddle -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$DD" "${extra[@]}" build | grep -E " error:|BUILD (SUCCEEDED|FAILED)"
APP="$DD/Build/Products/Release-iphoneos/Poddle.app"
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" com.mikecann.poddle
