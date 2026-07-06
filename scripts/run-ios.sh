#!/usr/bin/env bash
# One command to build and run the Artist OS companion in the iOS Simulator.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null 2>&1 || { echo "▸ installing xcodegen…"; brew install xcodegen; }

cd apps/ios
echo "▸ generating Xcode project…"
xcodegen generate

DEVICE="${SIM_DEVICE:-iPhone 16}"
echo "▸ booting $DEVICE simulator…"
open -a Simulator
xcrun simctl boot "$DEVICE" 2>/dev/null || true

echo "▸ building…"
xcodebuild -project ArtistOS.xcodeproj -scheme ArtistOSMobile -configuration Debug \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

APP="$(find build -name 'ArtistOSMobile.app' -path '*iphonesimulator*' | head -1)"
[ -n "$APP" ] || { echo "✗ built app not found"; exit 1; }

echo "▸ installing + launching…"
xcrun simctl install booted "$APP"
xcrun simctl launch booted com.stickley.artistos.mobile
echo "✓ running in Simulator"
