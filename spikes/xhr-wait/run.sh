#!/bin/bash
# Build the xhr-wait spike for the iOS simulator, run the cases, print JSON.
#
#   ./run.sh                       engine-like web view (1×1, opacity 0.01)
#   VIEW=visible ./run.sh          full screen
#   VIEW=detached ./run.sh         not in the window
#   POLICY=none ./run.sh           inactiveSchedulingPolicy = .none (as the app)
#   REPEAT=3 ./run.sh              run the cases 3 times
#   CASES=focus ./run.sh           only the cases that showed stalls
#   HEARTBEAT=50 ./run.sh          a 50 ms timer on the page while they run
#   SIM=<udid> ./run.sh            a specific simulator (default: booted)
set -euo pipefail
cd "$(dirname "$0")"

DEVICE="${SIM:-booted}"
BUNDLE_ID=dev.terrarium.spike.xhrwait
APP=build/XHRWaitSpike.app

rm -rf "$APP"
mkdir -p "$APP"
xcrun -sdk iphonesimulator swiftc \
  -swift-version 6 \
  -target arm64-apple-ios26.0-simulator \
  -parse-as-library -O \
  Sources/*.swift -o "$APP/XHRWaitSpike"
cp Info.plist "$APP/"
cp -R web "$APP/web"
codesign --force --sign - --timestamp=none "$APP" >/dev/null

xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"
DATA=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)
RESULT="$DATA/Documents/result.json"
rm -f "$RESULT"
SIMCTL_CHILD_XHRWAIT_VIEW="${VIEW:-engine}" SIMCTL_CHILD_XHRWAIT_POLICY="${POLICY:-}" \
  SIMCTL_CHILD_XHRWAIT_STEPS="repeat=${REPEAT:-2}&heartbeat=${HEARTBEAT:-0}&cases=${CASES:-all}" \
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID" >/dev/null
for _ in $(seq 1 ${TIMEOUT:-300}); do
  [ -f "$RESULT" ] && break
  sleep 1
done
[ -f "$RESULT" ] || { echo "no result" >&2; exit 1; }
cat "$RESULT"
