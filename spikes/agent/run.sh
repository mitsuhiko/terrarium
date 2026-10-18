#!/bin/bash
# Build the agent spike for the iOS simulator, start the mock model server on
# the Mac, launch the app and print its result (JSON).
#
#   ./run.sh                     all steps (real is skipped without --real)
#   ./run.sh --selftest          same (the name the other spikes use)
#   ./run.sh boot,storage        some steps
#   ./run.sh --real              also call the real Anthropic API with $ANTHROPIC_API_KEY
#   ./run.sh oauth-mock          automated OAuth login against the mock (loopback + browser sheet)
#   ./run.sh oauth:anthropic:browser   a real sign-in you complete in the simulator (10 min timeout)
#   ./run.sh apikey:openai       paste a real API key in the simulator
#   ./run.sh logins / logout     list / remove the credentials in the Keychain
#   SIM=<udid> ./run.sh          a specific simulator (default: booted)
set -euo pipefail
cd "$(dirname "$0")"

STEPS=all
REAL=0
for arg in "$@"; do
  case "$arg" in
    --selftest) ;;
    --real) REAL=1 ;;
    *) STEPS="$arg" ;;
  esac
done

DEVICE="${SIM:-booted}"
BUNDLE_ID=dev.terrarium.spike.agent
APP=build/Agent.app
PORT=8765
MOCK_KEY="mock-$RANDOM$RANDOM"

(cd web && { [ -d node_modules ] || npm install --silent; } && npx vite build --logLevel error)

rm -rf build
mkdir -p "$APP"
xcrun -sdk iphonesimulator swiftc \
  -swift-version 6 \
  -target arm64-apple-ios26.0-simulator \
  -parse-as-library -O \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker Entitlements.plist \
  Sources/*.swift -o "$APP/Agent"
cp Info.plist "$APP/"
cp -R web/dist "$APP/web"
codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "bundle: $(du -sk "$APP/web/assets" | cut -f1) KB of web assets ($(find "$APP/web/assets" -name '*.js' -exec cat {} + | gzip -c | wc -c | tr -d ' ') bytes of JS gzipped)" >&2

MOCK_KEY="$MOCK_KEY" uv run --quiet mock/server.py "$PORT" 2>build/mock.log &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  curl -sf "http://127.0.0.1:$PORT/stats" >/dev/null && break
  sleep 0.1
done

xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"
DATA=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)
RESULT="$DATA/Documents/agent-result.json"
rm -rf "$RESULT" "$DATA/Documents/agent-log.txt" "$DATA/Documents/db" "$DATA/Documents/project"

export SIMCTL_CHILD_TERRARIUM_STEPS="$STEPS"
export SIMCTL_CHILD_TERRARIUM_MOCK_URL="http://127.0.0.1:$PORT"
export SIMCTL_CHILD_TERRARIUM_MOCK_KEY="$MOCK_KEY"
if [ "$REAL" = 1 ]; then
  : "${ANTHROPIC_API_KEY:?--real needs ANTHROPIC_API_KEY}"
  export SIMCTL_CHILD_ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
fi
xcrun simctl launch "$DEVICE" "$BUNDLE_ID" >/dev/null

WAIT=240 # half-seconds
case "$STEPS" in *oauth:*|*apikey:*) WAIT=7200 ;; esac # an hour for sign-ins
for _ in $(seq 1 "$WAIT"); do
  [ -f "$RESULT" ] && break
  sleep 0.5
done
if [ ! -f "$RESULT" ]; then
  echo "no result after $((WAIT / 2))s; log:" >&2
  cat "$DATA/Documents/agent-log.txt" >&2 || true
  exit 1
fi
cat "$RESULT"
