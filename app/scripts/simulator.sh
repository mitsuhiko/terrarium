#!/bin/bash
# Print the UDID of an iOS simulator to run the app in, booting it (and
# opening Simulator.app) if needed.
#
#   scripts/simulator.sh iphone ["iPhone 18 Pro"]
#   scripts/simulator.sh ipad ["iPad Pro 13-inch (M5)"]
#   scripts/simulator.sh duo ["iPhone Duo"]
#
# Picks the named device, else a booted one of that kind, else the first
# available one (newest iOS first).
set -euo pipefail
KIND=${1:?usage: simulator.sh iphone|ipad|duo [name]}
NAME=${2:-}
case "$KIND" in
  iphone) PREFIX="iPhone" ;;
  ipad) PREFIX="iPad" ;;
  duo) PREFIX="iPhone Duo" ;;
  *) echo "unknown kind $KIND (iphone, ipad or duo)" >&2; exit 2 ;;
esac

UDID=$(xcrun simctl list devices available -j | NAME="$NAME" PREFIX="$PREFIX" python3 -c '
import json, os, sys
devices = []
for runtime, entries in json.load(sys.stdin)["devices"].items():
    if ".iOS-" not in runtime:
        continue
    version = tuple(int(p) for p in runtime.rsplit(".iOS-", 1)[1].split("-"))
    devices += [(version, d) for d in entries if d["name"].startswith(os.environ["PREFIX"])]
devices.sort(key=lambda vd: vd[0], reverse=True)
name = os.environ["NAME"]
pick = next((d for _, d in devices if name and d["name"] == name), None)
pick = pick or next((d for _, d in devices if not name and d["state"] == "Booted"), None)
pick = pick or (devices[0][1] if devices else None)
print(pick["udid"] if pick else "")
')
[ -n "$UDID" ] || { echo "no ${PREFIX} simulator${NAME:+ named \"$NAME\"} (Xcode > Settings > Components)" >&2; exit 1; }

if ! xcrun simctl list devices | grep "$UDID" | grep -q Booted; then
  xcrun simctl boot "$UDID"
fi
open -a Simulator --args -CurrentDeviceUDID "$UDID" >/dev/null 2>&1 || true
echo "$UDID"
