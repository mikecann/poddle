#!/bin/zsh
# Build a Release app (pointing at prod), install it on Mike's phone and launch it.
# With the App Store Connect API key in ~/.config/poddle it signs with push via automatic
# provisioning, no Xcode account needed. Without it, it builds without push using the
# existing wildcard profile.
#
# SRC=<checkout> builds another checkout (a worktree, say) instead of this one, CONFIG=Debug
# builds against dev, LAUNCH_ARGS are passed to the app, and BUILD_ONLY=1 stops after the build.
set -euo pipefail
cd "${SRC:-$(dirname "$0")/..}"
CONFIG=${CONFIG:-Release}
DEVICE=${DEVICE:-00008130-001939C80483401C}   # 15 Pro Max
DD=${DD:-/tmp/poddle-dd-device}
ASC_KEY_ID=${ASC_KEY_ID:-7SS6J9F98P}
ASC_ISSUER_ID=${ASC_ISSUER_ID:-69a6de6f-a06e-47e3-e053-5b8c7c11a4d1}
ASC_KEY=${ASC_KEY:-$HOME/.config/poddle/AuthKey_$ASC_KEY_ID.p8}
extra=()
if [[ -f "$ASC_KEY" && "${PUSH:-1}" == 1 ]]; then
  extra+=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration
    -authenticationKeyPath "$ASC_KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
else
  echo "No API key at $ASC_KEY (or PUSH=0): building without push"
  extra+=(CODE_SIGN_ENTITLEMENTS=)
fi
xcodebuild -project Poddle.xcodeproj -scheme Poddle -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' -derivedDataPath "$DD" "${extra[@]}" build | grep -E " error:|BUILD (SUCCEEDED|FAILED)"
APP="$DD/Build/Products/$CONFIG-iphoneos/Poddle.app"
[[ "${BUILD_ONLY:-0}" == 1 ]] && { echo "Built $APP"; exit 0; }
xcrun devicectl device install app --device "$DEVICE" "$APP"
launch=(--terminate-existing com.mikecann.poddle)
[[ -n "${LAUNCH_ARGS:-}" ]] && launch+=(-- ${=LAUNCH_ARGS})
xcrun devicectl device process launch --device "$DEVICE" "${launch[@]}"
