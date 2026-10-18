#!/bin/bash
# Build the native-stack spike for the iOS simulator, run the cases, print JSON.
#
#   STEPS="modes=sync,async&n=100000" ./run.sh       where each case crashes
#   STEPS="limits=0,49152&kinds=crash,normal" ./run.sh   with stack protection
#   STEPS="find=1&warm=generic&n=20000" ./run.sh     the deepest N before the crash
#   SIM=<udid> ./run.sh                              a specific simulator (default: booted)
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID=dev.terrarium.spike.nativestack
APP=build/NativeStackSpike.app

rm -rf "$APP"
mkdir -p "$APP"
xcrun -sdk iphonesimulator swiftc -swift-version 6 -target arm64-apple-ios26.0-simulator \
  -parse-as-library -O Sources/*.swift -o "$APP/NativeStackSpike"
cp Info.plist "$APP/"
cp -R web "$APP/web"
mkdir -p "$APP/web/pyodide"
for v in 3.14:pyodide-314.0.7 3.15:pyodide-315.0.0-alpha.2; do
  mkdir -p "$APP/web/pyodide/${v%%:*}"
  cp ../../app/vendor/${v#*:}/{pyodide.mjs,pyodide.asm.mjs,pyodide.asm.wasm,python_stdlib.zip,pyodide-lock.json} "$APP/web/pyodide/${v%%:*}/"
done

codesign --force --sign - --timestamp=none "$APP" >/dev/null
DEVICE="${SIM:-booted}"
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"
DATA=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)
RESULT="$DATA/Documents/result.json"
rm -f "$RESULT"
SIMCTL_CHILD_NATIVESTACK_STEPS="${STEPS:-}" xcrun simctl launch "$DEVICE" "$BUNDLE_ID" >/dev/null
for _ in $(seq 1 ${TIMEOUT:-900}); do
  [ -f "$RESULT" ] && break
  sleep 1
done
[ -f "$RESULT" ] || { echo "no result; log:" >&2; cat "$DATA/Documents/log.txt" >&2; exit 1; }
cat "$RESULT"
