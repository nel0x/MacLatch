#!/bin/bash
# Builds build/MacLatch.app (release, ad-hoc signed).
#   --install   also replace /Applications/MacLatch.app and (re)start it
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release --product MacLatch
BIN="$(swift build -c release --show-bin-path)/MacLatch"

APP=build/MacLatch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/MacLatch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST=/Applications/MacLatch.app
    pkill -x MacLatch && sleep 1 || true   # quit running instances (SIGTERM)
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    open "$DEST"
    echo "Installed and started $DEST"
fi
