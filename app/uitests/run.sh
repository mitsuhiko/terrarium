#!/bin/bash
# UI stress runs against the installed app (install it with ../run.sh first).
#
#   ./run.sh monkey [SEED] [STEPS]   random taps with checks (FAST=1: during animations, ROTATE=1: rotate too)
#   ./run.sh scenarios [TIMES]       the wide layout's transitions (ONLY=split,move ...)
#   ./run.sh dump                    the hierarchy as XCTest sees it
#   ./run.sh script "tap:Hide Files;rotate:landscapeLeft;wait:1;shot:name"   (NAME=<out dir>)
#   SIM=<udid> ./run.sh ...          a simulator (default: the booted one)
#
# Prints the anomalies and what the app logged under Diagnostics (hangs, web
# views off their place); screenshots and logs are in build/out-<run>/.
set -uo pipefail
cd "$(dirname "$0")"
KIND=${1:-monkey}
SIM=${SIM:-$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)}
[ -n "$SIM" ] || { echo "no booted simulator" >&2; exit 2; }
case "$KIND" in
  monkey) TEST=Monkey; export TEST_RUNNER_SEED=${2:-1} TEST_RUNNER_STEPS=${3:-200}; NAME=monkey-$TEST_RUNNER_SEED ;;
  scenarios) TEST=Scenarios; export TEST_RUNNER_TIMES=${2:-8}; NAME=scenarios ;;
  dump) TEST=Dump; NAME=dump ;;
  script) TEST=Script; export TEST_RUNNER_SCRIPT=${2:?steps}; NAME=${NAME:-script} ;;
  *) echo "unknown run $KIND" >&2; exit 2 ;;
esac
for v in FAST ROTATE ONLY; do [ -n "${!v:-}" ] && export TEST_RUNNER_$v="${!v}"; done
OUT=$PWD/build/out-$NAME
rm -rf "$OUT"; mkdir -p "$OUT"
export TEST_RUNNER_OUT=$OUT

DUO=0; xcrun simctl io "$SIM" enumerate 2> /dev/null | grep -q "Device Name: primary-1" && DUO=1
# Screenshots on request (XCUIScreen's are black on the iPhone Duo's inner screen).
( while true; do
    for r in "$OUT"/req-*; do
      [ -e "$r" ] || continue
      n=$(basename "$r"); n=${n#req-}
      if [ "$DUO" = 1 ]; then # both screens: one of them is off
        for d in primary primary-1; do
          xcrun simctl io "$SIM" screenshot --display=$d "$OUT/$n-$d.png" > /dev/null 2>&1 && sips -Z 900 "$OUT/$n-$d.png" > /dev/null 2>&1
        done
      else
        xcrun simctl io "$SIM" screenshot "$OUT/$n.png" > /dev/null 2>&1 && sips -Z 900 "$OUT/$n.png" > /dev/null 2>&1
      fi
      rm -f "$r"
    done
    sleep 0.2
  done ) &
SHOOTER=$!
xcrun simctl spawn "$SIM" log stream --style compact --predicate 'subsystem == "eu.ronacher.Terrarium"' > "$OUT/app.log" 2>&1 &
LOGGER=$!
trap 'kill $SHOOTER $LOGGER 2> /dev/null' EXIT

xcodebuild test -project StressUI.xcodeproj -scheme StressUI -destination "id=$SIM" -derivedDataPath build/dd \
  -only-testing:StressUI/$TEST > "$OUT/xcodebuild.log" 2>&1
STATUS=$?
sleep 1
grep -E "error:|\*\* TEST" "$OUT/xcodebuild.log" | grep -v invalidDigitCount
echo "anomalies:"; cat "$OUT/anomalies.txt" 2> /dev/null; echo
echo "app diagnostics:"; grep -E "Diagnostics|WebViewSlot" "$OUT/app.log" | grep -v "^Filtering"
[ "$KIND" = dump ] && echo "tree: $OUT/tree.txt"
echo "out: $OUT"
exit $STATUS
