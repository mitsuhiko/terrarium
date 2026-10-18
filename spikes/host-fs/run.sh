#!/bin/bash
# Build the host-fs spike for the iOS simulator, run the benchmark, print JSON.
#
#   ./run.sh                 all steps
#   ./run.sh transport,python   some steps (probe, transport, python, check, copy, crash)
#   SIM=<udid> ./run.sh      a specific simulator (default: booted)
set -euo pipefail
cd "$(dirname "$0")"

STEPS="${1:-all}"
DEVICE="${SIM:-booted}"
BUNDLE_ID=dev.terrarium.spike.hostfs
APP=build/HostFSSpike.app
PYODIDE=../../app/vendor/pyodide-314.0.7
[ -d "$PYODIDE" ] || { echo "missing $PYODIDE; run app/scripts/fetch-pyodide.sh" >&2; exit 1; }

rm -rf build
mkdir -p "$APP"
xcrun -sdk iphonesimulator swiftc \
  -swift-version 6 \
  -target arm64-apple-ios26.0-simulator \
  -parse-as-library -O \
  Sources/*.swift -o "$APP/HostFSSpike"
cp Info.plist "$APP/"
cp -R web "$APP/web"
mkdir -p "$APP/web/pyodide"
for f in pyodide.mjs pyodide.asm.mjs pyodide.asm.wasm python_stdlib.zip pyodide-lock.json; do
  cp "$PYODIDE/$f" "$APP/web/pyodide/"
done
codesign --force --sign - --timestamp=none "$APP" >/dev/null

xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"
DATA=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)
RESULT="$DATA/Documents/result.json"
rm -f "$RESULT"
SIMCTL_CHILD_HOSTFS_STEPS="$STEPS" xcrun simctl launch "$DEVICE" "$BUNDLE_ID" >/dev/null
for _ in $(seq 1 ${TIMEOUT:-300}); do
  [ -f "$RESULT" ] && break
  sleep 1
done
if [ ! -f "$RESULT" ]; then
  echo "no result after ${TIMEOUT:-300}s; log:" >&2
  cat "$DATA/Documents/log.txt" >&2 2>/dev/null || true
  exit 1
fi
cat "$RESULT"
