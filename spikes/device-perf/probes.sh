#!/bin/bash
# Runs all device probes in one session. Keep the phone unlocked (Auto-Lock:
# Never) and don't touch it while this runs (about 5 minutes).
set -uo pipefail
cd "$(dirname "$0")"
mkdir -p build/probes
BUNDLE_ID=eu.ronacher.TerrariumSpike
DEVICE="${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | grep physical | grep -E 'available|connected' | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)}"
export DEVICE

run() { # name, run.sh args...
  local name=$1; shift
  echo "== $name"
  TIMEOUT=${TIMEOUT:-240} ./run.sh --no-build "$@" > "build/probes/$name.json" 2>&1
  echo "   exit $? -> build/probes/$name.json"
}

./run.sh --page index.html > /dev/null 2>&1 || { echo "build/install failed"; exit 1; }

run stack-depth --page jspi/index.html --query "only=stack_depth" --selftest ""
run crec-worker --selftest crec
run crec-main --page jspi/pyodide-main.html --selftest ""
run memory --selftest memory_ceiling

# Backgrounding: start a 75 s ticking script, switch to Settings for 30 s,
# then bring the app back and collect the result.
echo "== background"
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID" \
  --selftest background_ticks > /dev/null 2>&1
sleep 15
xcrun devicectl device process launch --device "$DEVICE" com.apple.Preferences > /dev/null 2>&1
sleep 30
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" > /dev/null 2>&1
for _ in $(seq 1 40); do
  sleep 3
  if xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
      --domain-identifier "$BUNDLE_ID" --source Documents/probe-result.json \
      --destination build/probes/background.json > /dev/null 2>&1; then
    break
  fi
done
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" --source Documents/probe-log.txt \
  --destination build/probes/background-log.txt > /dev/null 2>&1
echo "   -> build/probes/background.json"
