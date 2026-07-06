#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/preflight.sh || exit 1
./scripts/package-macos-app.sh debug
echo "▸ launching Artist OS…"; open build/ArtistOS.app
