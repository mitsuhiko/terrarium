#!/bin/bash
# Build and run Terrarium.
#
#   ./run.sh                     simulator (booted), interactive
#   ./run.sh --selftest          simulator, run the end-to-end checks, print JSON
#   ./run.sh --device [...]      on the paired iPhone (must be unlocked)
#   ./run.sh --reset ...         wipe Documents first (examples get re-seeded)
#   QUERY="jspi=0&gc=0" ./run.sh ...   runtime switches
set -euo pipefail
cd "$(dirname "$0")"

TARGET=simulator
SELFTEST=0
RESET=0
for arg in "$@"; do
  case "$arg" in
    --device) TARGET=device ;;
    --selftest) SELFTEST=1 ;;
    --reset) RESET=1 ;;
    *) echo "unknown argument $arg" >&2; exit 2 ;;
  esac
done

BUNDLE_ID=eu.ronacher.pyterrarium
mkdir -p build
./scripts/fetch-pyodide.sh
./scripts/build-docs.py   # no-op when vendor/docs-* match the pinned archives
./scripts/build-ty.sh   # no-op when vendor/ty_wasm matches the pinned revision
(cd web && { [ -d node_modules ] || npm install --silent; } && npm run build --silent > ../build/vite.log 2>&1) \
  || { cat build/vite.log; exit 1; }

ARGS=()
[ "$SELFTEST" = 1 ] && ARGS+=(--selftest)
[ "$RESET" = 1 ] && ARGS+=(--reset)
[ -n "${QUERY:-}" ] && ARGS+=(--query "$QUERY")
[ -n "${FRAGMENT:-}" ] && ARGS+=(--fragment "$FRAGMENT")

if [ "$TARGET" = simulator ]; then
  xcodebuild -project ios/Terrarium.xcodeproj -scheme Terrarium -configuration Debug \
    -destination "generic/platform=iOS Simulator" -derivedDataPath build/dd \
    CODE_SIGNING_ALLOWED=NO build > build/xcodebuild.log 2>&1 || { grep -E "error:" build/xcodebuild.log | head -20; tail -5 build/xcodebuild.log; exit 1; }
  APP=build/dd/Build/Products/Debug-iphonesimulator/Terrarium.app
  xcrun simctl terminate "${SIM:-booted}" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl install "${SIM:-booted}" "$APP"
  if [ "$SELFTEST" = 1 ]; then
    # The device modules' checks (D40) can't answer permission prompts.
    for service in all contacts reminders photos location microphone motion; do
      xcrun simctl privacy "${SIM:-booted}" grant "$service" "$BUNDLE_ID" 2>/dev/null || true
    done
    xcrun simctl location "${SIM:-booted}" set 48.8582,2.2945 2>/dev/null || true
  fi
  DOCS="$(xcrun simctl get_app_container "${SIM:-booted}" "$BUNDLE_ID" data)/Documents"
  rm -f "$DOCS/.probe-result.json"
  xcrun simctl launch "${SIM:-booted}" "$BUNDLE_ID" ${ARGS[@]+"${ARGS[@]}"} > /dev/null
  [ "$SELFTEST" = 1 ] || exit 0
  for _ in $(seq 1 ${TIMEOUT:-180}); do
    [ -f "$DOCS/.probe-result.json" ] && { cat "$DOCS/.probe-result.json"; exit 0; }
    sleep 1
  done
  echo "no result; log:" >&2
  cat "$DOCS/.probe-log.txt" >&2 2>/dev/null
  exit 1
fi

# Xcode 27's devicectl lists simulators too (Reality: simulated); older ones said "physical".
DEVICE="${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | grep -v simulated | grep -E 'available|connected' | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1 || true)}"
[ -n "$DEVICE" ] || { echo "no paired device" >&2; exit 1; }
# Release, but with the self-test's private-API hooks (SELFTEST_SPI, D51); scripts/archive.sh builds without them.
xcodebuild -project ios/Terrarium.xcodeproj -scheme Terrarium -configuration Release \
  -destination "id=$DEVICE" -derivedDataPath build/dd -allowProvisioningUpdates \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=SELFTEST_SPI build > build/xcodebuild.log 2>&1 \
  || { grep -E "error:" build/xcodebuild.log | head -20; exit 1; }
xcrun devicectl device install app --device "$DEVICE" build/dd/Build/Products/Release-iphoneos/Terrarium.app > build/install.log 2>&1 \
  || { cat build/install.log; exit 1; }
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID" ${ARGS[@]+"${ARGS[@]}"} > build/launch.log 2>&1 \
  || { cat build/launch.log; exit 1; }
[ "$SELFTEST" = 1 ] || exit 0
for _ in $(seq 1 $(( ${TIMEOUT:-240} / 3 ))); do
  sleep 3
  if xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source Documents/.probe-result.json --destination build/device-result.json > /dev/null 2>&1; then
    cat build/device-result.json
    exit 0
  fi
done
echo "no result from device" >&2
exit 1
