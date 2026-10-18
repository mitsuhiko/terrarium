#!/bin/bash
# Build the Pyodide spike for the iOS simulator and run it.
#   ./run.sh              build, install, launch (interactive)
#   ./run.sh --selftest   ... and run the scripted checks, print the results
set -euo pipefail
cd "$(dirname "$0")"

PYODIDE_VERSION=314.0.7
DEVICE="${DEVICE:-booted}"
BUNDLE_ID=dev.terrarium.spike.pyodide
APP=build/PyodideSpike.app
VENDOR=vendor/pyodide-$PYODIDE_VERSION

if [ ! -d "$VENDOR" ]; then
  mkdir -p vendor
  (cd vendor && npm pack "pyodide@$PYODIDE_VERSION" >/dev/null && tar xzf "pyodide-$PYODIDE_VERSION.tgz" \
    && mv package "pyodide-$PYODIDE_VERSION" && rm "pyodide-$PYODIDE_VERSION.tgz")
fi

rm -rf build
mkdir -p "$APP"
xcrun -sdk iphonesimulator swiftc \
  -swift-version 6 \
  -target arm64-apple-ios26.0-simulator \
  -parse-as-library -O \
  Sources/*.swift -o "$APP/PyodideSpike"
cp Info.plist "$APP/"
cp -R web "$APP/web"
# EXTRA_WEB="dir:name ..." copies other spikes' web dirs into the app (web/<name>)
for spec in ${EXTRA_WEB:-}; do
  cp -R "${spec%%:*}" "$APP/web/${spec##*:}"
done
mkdir -p "$APP/web/pyodide"
for f in pyodide.mjs pyodide.asm.mjs pyodide.asm.wasm python_stdlib.zip pyodide-lock.json; do
  cp "$VENDOR/$f" "$APP/web/pyodide/"
done
codesign --force --sign - --timestamp=none "$APP" >/dev/null

xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"
DATA=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)
RESULT="$DATA/Documents/probe-result.json"
LOG="$DATA/Documents/probe-log.txt"
rm -f "$RESULT" "$LOG"

if [ "${1:-}" != "--selftest" ]; then
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID" --page "${PAGE:-}" --query "${QUERY:-}" --fragment "${FRAGMENT:-}" >/dev/null
  exit 0
fi

xcrun simctl launch "$DEVICE" "$BUNDLE_ID" --selftest "${2:-}" --page "${PAGE:-}" --query "${QUERY:-}" >/dev/null
for _ in $(seq 1 ${TIMEOUT:-240}); do
  [ -f "$RESULT" ] && break
  sleep 1
done
if [ ! -f "$RESULT" ]; then
  echo "no result after ${TIMEOUT:-240}s; log:" >&2
  cat "$LOG" >&2 2>/dev/null || true
  exit 1
fi
cat "$RESULT"
