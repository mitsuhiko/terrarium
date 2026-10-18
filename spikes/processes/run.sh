#!/bin/bash
# Build the processes spike for the iOS simulator, run the tests, print JSON.
#
#   ./run.sh                          all tests
#   ./run.sh t_basic,t_pool           some tests
#   WARM=4 PRELOAD=0 ./run.sh         warm pool size, preloading off
#   PYODIDE=315.0.0-alpha.2 ./run.sh  the 3.15 preview
#   SIM=<udid> ./run.sh               a specific simulator (default: booted)
#
# Also samples the simulator's WebContent memory (sample-memory.mjs) and adds
# each test's peak to the JSON.
set -euo pipefail
cd "$(dirname "$0")"

TESTS="${1:-}"
DEVICE="${SIM:-booted}"
VERSION="${PYODIDE:-314.0.7}"
BUNDLE_ID=dev.terrarium.spike.processes
APP=build/ProcessesSpike.app
PYODIDE_DIR=../../app/vendor/pyodide-$VERSION
[ -d "$PYODIDE_DIR" ] || { echo "missing $PYODIDE_DIR; run app/scripts/fetch-pyodide.sh" >&2; exit 1; }
[ -d "build/pkgs-$VERSION" ] || node fetch-packages.mjs >&2

rm -rf "$APP"
mkdir -p "$APP"
xcrun -sdk iphonesimulator swiftc \
  -swift-version 6 \
  -target arm64-apple-ios26.0-simulator \
  -parse-as-library -O \
  Sources/*.swift -o "$APP/ProcessesSpike"
cp Info.plist "$APP/"
cp -R web "$APP/web"
(cd web/tests && ls *.py | node -e 'console.log(JSON.stringify(require("fs").readFileSync(0,"utf8").trim().split("\n")))') > "$APP/web/tests/index.json"
mkdir -p "$APP/web/pyodide" "$APP/web/pkgs"
for f in pyodide.mjs pyodide.asm.mjs pyodide.asm.wasm python_stdlib.zip pyodide-lock.json; do
  cp "$PYODIDE_DIR/$f" "$APP/web/pyodide/"
done
cp build/pkgs-"$VERSION"/*.whl "$APP/web/pkgs/" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP" >/dev/null

xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"
DATA=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)
RESULT="$DATA/Documents/result.json"
rm -f "$RESULT"
MEM=build/memory-samples.jsonl
node sample-memory.mjs > "$MEM" &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null || true' EXIT
sleep 1
OPTIONS="warm=${WARM:-2}&preload=${PRELOAD:-1}&pyodide=$VERSION"
[ -n "$TESTS" ] && OPTIONS="$OPTIONS&tests=$TESTS"
SIMCTL_CHILD_PROCS_OPTIONS="$OPTIONS" xcrun simctl launch "$DEVICE" "$BUNDLE_ID" >/dev/null
for _ in $(seq 1 ${TIMEOUT:-900}); do
  [ -f "$RESULT" ] && break
  sleep 1
done
kill $SAMPLER 2>/dev/null || true
if [ ! -f "$RESULT" ]; then
  echo "no result after ${TIMEOUT:-900}s; log:" >&2
  tail -50 "$DATA/Documents/log.txt" >&2 2>/dev/null || true
  exit 1
fi
node -e '
const fs = require("fs");
const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const samples = fs.readFileSync(process.argv[2], "utf8").trim().split("\n").map((l) => JSON.parse(l));
const mb = (kb) => Math.round(kb / 1024);
// Only WebContent processes that appeared after the first sample are ours.
const before = new Set(Object.keys(samples[0]?.procs ?? {}));
const ours = (s) => Object.entries(s.procs).filter(([pid]) => !before.has(pid)).reduce((a, [, kb]) => a + kb, 0);
result.memory = { otherWebContentMB: mb(samples[0]?.total ?? 0), peakMB: mb(Math.max(...samples.map(ours))) };
for (const t of Object.values(result.tests ?? {})) {
  const inside = samples.filter((s) => s.t >= t.startedAt && s.t <= t.endedAt);
  if (inside.length) t.peakMemoryMB = mb(Math.max(...inside.map(ours)));
  // t_memory: the median in each phase window ("phase N at" + 2 s).
  for (const [name, at] of Object.entries(t.metrics ?? {})) {
    const m = name.match(/^phase (\d+) at$/);
    if (!m) continue;
    const xs = samples.filter((s) => s.t >= at + 300 && s.t <= at + 1900).map(ours).sort((a, b) => a - b);
    if (xs.length) (t.phasesMB ??= {})[m[1]] = mb(xs[Math.floor(xs.length / 2)]);
  }
}
console.log(JSON.stringify(result, null, 2));
' "$RESULT" "$MEM"
