#!/usr/bin/env bash
# Prepare BOTH apps to run on your physical devices from Xcode.
# You only pick your Apple ID team once; then hit Run (▶) to your iPhone.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null 2>&1 || { echo "▸ installing xcodegen…"; brew install xcodegen; }

echo "▸ generating the iOS Xcode project…"
( cd apps/ios && xcodegen generate )

echo ""
echo "✓ Ready. To demo on your iPhone:"
echo "   1. Opening apps/ios/ArtistOS.xcodeproj now…"
echo "   2. In Xcode: select the ArtistOSMobile target → Signing & Capabilities"
echo "   3. Check 'Automatically manage signing' and pick your Team (your Apple ID)."
echo "   4. Plug in your iPhone, select it as the run destination, press ▶."
echo ""
echo "   (macOS app: run 'make mac' — no signing needed to run it locally.)"
open apps/ios/ArtistOS.xcodeproj
