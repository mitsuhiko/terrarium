#!/bin/bash
# Build, install and run the spike host on a physical iPhone, then pull the
# result JSON back. The phone must be unlocked.
#
#   ./run.sh [--no-build] --page <page> [--selftest <steps>] [--query <q>] [--fragment <f>]
#   DEVICE=<udid> ./run.sh ...      (default: first paired physical iPhone)
#
# Examples:
#   ./run.sh --selftest ""                                 # pyodide-worker suite
#   ./run.sh --selftest "" --query "gc=1&jspi=1"
#   ./run.sh --page ui/index.html --selftest ""            # ui-toolkit suite
#   ./run.sh --page jspi/index.html?r=1 --selftest ""      # minimal JSPI tests
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID=eu.ronacher.TerrariumSpike
APP=build/dd/Build/Products/Release-iphoneos/DevicePerf.app
DEVICE="${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | grep physical | grep -E 'available|connected' | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)}"
TIMEOUT="${TIMEOUT:-300}"
[ -n "$DEVICE" ] || { echo "no paired physical device found" >&2; exit 1; }

BUILD=1
if [ "${1:-}" = "--no-build" ]; then BUILD=0; shift; fi

if [ "$BUILD" = 1 ]; then
  xcodebuild -project DevicePerf.xcodeproj -scheme DevicePerf -configuration Release \
    -destination "id=$DEVICE" -derivedDataPath build/dd -allowProvisioningUpdates build \
    > build/xcodebuild.log 2>&1 || { tail -30 build/xcodebuild.log; exit 1; }
  xcrun devicectl device install app --device "$DEVICE" "$APP" > build/install.log 2>&1 \
    || { cat build/install.log; exit 1; }
fi

xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID" "$@" \
  > build/launch.log 2>&1 || { cat build/launch.log; exit 1; }

case " $* " in *" --selftest "*) ;; *) exit 0 ;; esac

RESULT=build/probe-result.json
LOG=build/probe-log.txt
rm -f "$RESULT" "$LOG"
for _ in $(seq 1 $((TIMEOUT / 3))); do
  sleep 3
  if xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
      --domain-identifier "$BUNDLE_ID" --source Documents/probe-result.json --destination "$RESULT" \
      > /dev/null 2>&1; then
    cat "$RESULT"
    exit 0
  fi
done
echo "no result after ${TIMEOUT}s; log:" >&2
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" --source Documents/probe-log.txt --destination "$LOG" > /dev/null 2>&1 \
  && cat "$LOG" >&2
exit 1
