#!/usr/bin/env bash
# Wrap the SwiftPM build output into a real, double-clickable ArtistOS.app.
# Reuses the proven `swift build` path (no separate Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
EXE="$BIN_PATH/ArtistOS"
[ -f "$EXE" ] || { echo "✗ executable not found at $EXE"; exit 1; }

APP="build/ArtistOS.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXE" "$APP/Contents/MacOS/ArtistOS"
chmod +x "$APP/Contents/MacOS/ArtistOS"

# Copy any SwiftPM resource bundles (GRDB etc.) next to the binary so the .app is self-contained.
find "$BIN_PATH" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/MacOS/" \; 2>/dev/null || true

cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Artist OS</string>
  <key>CFBundleDisplayName</key><string>Artist OS</string>
  <key>CFBundleExecutable</key><string>ArtistOS</string>
  <key>CFBundleIdentifier</key><string>com.stickley.artistos.mac</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
</dict>
</plist>
PLIST

echo "✓ Built $APP"
