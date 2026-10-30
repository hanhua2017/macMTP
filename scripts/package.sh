#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
# Keep the legacy bundle location, using the same dependency checks and signing.
bash "$PROJECT_DIR/scripts/build.sh" release "$@"
rm -rf "$PROJECT_DIR/.build/macMTP.app"
ditto "$PROJECT_DIR/macMTP.app" "$PROJECT_DIR/.build/macMTP.app"
echo "App bundle created at $PROJECT_DIR/.build/macMTP.app"
