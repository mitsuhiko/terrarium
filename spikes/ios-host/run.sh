#!/bin/bash
# Build the host spike for the iOS simulator, install it, launch it, and print
# the probe result. Usage: ./run.sh [simulator-name]   (default: booted device)
set -euo pipefail
cd "$(dirname "$0")"

DEVICE="${1:-booted}"
BUNDLE_ID=dev.terrarium.spike.host
APP=build/Host.app

rm -rf build
mkdir -p "$APP"
xcrun -sdk iphonesimulator swiftc \
  -swift-version 6 \
  -target arm64-apple-ios26.0-simulator \
  -parse-as-library -O \
  Sources/*.swift -o "$APP/Host"
cp Info.plist "$APP/"
cp -R web "$APP/web"
codesign --force --sign - --timestamp=none "$APP" >/dev/null

xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"
DATA=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)
RESULT="$DATA/Documents/probe-result.json"
rm -f "$RESULT" "$DATA/Documents/probe-log.txt"
xcrun simctl launch "$DEVICE" "$BUNDLE_ID" >/dev/null

for _ in $(seq 1 60); do
  [ -f "$RESULT" ] && break
  sleep 1
done
if [ ! -f "$RESULT" ]; then
  echo "no result after 60s; log:" >&2
  cat "$DATA/Documents/probe-log.txt" >&2 || true
  exit 1
fi
cat "$RESULT"
