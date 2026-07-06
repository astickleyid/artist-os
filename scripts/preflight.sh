#!/usr/bin/env bash
# Checks your Mac has what it needs, with plain-English fixes. Safe to run anytime.
set -uo pipefail
ok=0
echo "Artist OS — build preflight"
echo "----------------------------"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "✗ Xcode command-line tools not found → install Xcode from the App Store, then run: xcode-select --install"; ok=1
else
  echo "✓ Xcode tools: $(xcode-select -p)"
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "✗ xcodebuild not usable → open Xcode once to finish setup, then: sudo xcode-select -s /Applications/Xcode.app"; ok=1
else
  echo "✓ $(xcodebuild -version | head -1)"
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "✗ Homebrew missing → install from https://brew.sh (the scripts use it to get xcodegen)"; ok=1
else
  echo "✓ Homebrew present"
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "✗ swift not on PATH → comes with Xcode; finish the Xcode setup above"; ok=1
else
  echo "✓ $(swift --version 2>&1 | head -1)"
fi

echo "----------------------------"
[ "$ok" -eq 0 ] && echo "All good — run 'make mac', 'make ios', or 'make device'." || echo "Fix the ✗ items above, then re-run: ./scripts/preflight.sh"
exit $ok
