#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/preflight.sh || exit 1
command -v xcodegen >/dev/null 2>&1 || { echo "▸ installing xcodegen…"; brew install xcodegen; }
cd apps/ios
echo "▸ generating Xcode project…"; xcodegen generate
DEVICE="${SIM_DEVICE:-}"
if [ -z "$DEVICE" ]; then
  DEVICE="$(xcrun simctl list devices available | grep -oE 'iPhone [0-9]+( Pro( Max)?)?' | sort -V | tail -1 || true)"
fi
[ -n "$DEVICE" ] || { echo "✗ no iPhone simulator found (Xcode → Settings → Components)"; exit 1; }
echo "▸ simulator: $DEVICE"; open -a Simulator; xcrun simctl boot "$DEVICE" 2>/dev/null || true
echo "▸ building…"
xcodebuild -project ArtistOS.xcodeproj -scheme ArtistOSMobile -configuration Debug \
  -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build | tail -20
APP="$(find build -name 'ArtistOSMobile.app' -path '*iphonesimulator*' | head -1)"
[ -n "$APP" ] || { echo "✗ built app not found"; exit 1; }
echo "▸ installing + launching…"; xcrun simctl install booted "$APP"
xcrun simctl launch booted com.stickley.artistos.mobile; echo "✓ running in Simulator"
