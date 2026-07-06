#!/usr/bin/env bash
# One command to build and launch Artist OS on your Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/package-macos-app.sh debug
echo "▸ launching Artist OS…"
open build/ArtistOS.app
