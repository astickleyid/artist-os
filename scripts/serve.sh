#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../app/static"
python3 -m http.server 5173
