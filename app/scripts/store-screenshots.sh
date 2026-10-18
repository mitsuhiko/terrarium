#!/bin/bash
# App Store screenshots (D51): the sizes App Store Connect asks for, from the
# simulators, with a clean status bar, into build/screenshots/<device>/.
#
#   scripts/store-screenshots.sh              iPhone 6.9" and iPad 13"
#   scripts/store-screenshots.sh iphone       one of them
#   IPHONE="iPhone 18 Pro Max" IPAD="iPad Pro 13-inch (M5)" APPEARANCE=dark ...
#
# Each scene starts from a fresh app state (settings cleared, examples
# re-seeded with --reset) and uses the launch hooks (AppModel.launchHooks).
# The simulators' Documents are wiped. The plot and the notebook need the
# network the first time (numpy and matplotlib come from Pyodide's CDN).
set -euo pipefail
cd "$(dirname "$0")/.."

KINDS=("$@")
[ ${#KINDS[@]} -gt 0 ] || KINDS=(iphone ipad)
IPHONE=${IPHONE:-iPhone 18 Pro Max}
IPAD=${IPAD:-iPad Pro 13-inch (M5)}
APPEARANCE=${APPEARANCE:-light}
BUNDLE_ID=eu.ronacher.pyterrarium

# name|fragment|seconds to wait
IPHONE_SCENES=(
  "1-plot|open=Examples/Plot.py&run&pane=console|25"
  "2-debugger|open=Examples/Countdown.py&bp=5&run&pane=console|12"
  "3-todo|open=Examples/Todo App.py&run|12"
  "4-notebook|open=Examples/Notebook.ipynb&cells|25"
  "5-turtle|open=Examples/Turtle.py&run&pane=console|20"
  "6-docs|docs=3.14/library/json.html|8"
)
IPAD_SCENES=(
  "1-split|open=Examples/Plot.py&split=Examples/Turtle.py&run|25"
  "2-debugger|open=Examples/Countdown.py&bp=5&run|12"
  "3-notebook|open=Examples/Notebook.ipynb&cells|25"
  "4-todo|open=Examples/Todo App.py&run|12"
  "5-docs|docs=3.14/library/json.html|8"
)

for kind in "${KINDS[@]}"; do
  case "$kind" in
    iphone) NAME=$IPHONE; SCENES=("${IPHONE_SCENES[@]}") ;;
    ipad) NAME=$IPAD; SCENES=("${IPAD_SCENES[@]}") ;;
    *) echo "unknown device $kind (iphone or ipad)" >&2; exit 2 ;;
  esac
  UDID=$(./scripts/simulator.sh "$kind" "$NAME")
  echo "$kind: $NAME ($UDID)"
  SIM=$UDID ./run.sh   # build, install and launch once
  xcrun simctl ui "$UDID" appearance "$APPEARANCE"
  xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  OUT=build/screenshots/$kind
  mkdir -p "$OUT"
  for scene in "${SCENES[@]}"; do
    IFS='|' read -r shot fragment wait <<< "$scene"
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl spawn "$UDID" defaults delete "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID" --reset --fragment "$fragment" > /dev/null
    sleep "$wait"
    xcrun simctl io "$UDID" screenshot "$OUT/$shot.png" > /dev/null 2>&1
    echo "  $OUT/$shot.png ($(sips -g pixelWidth -g pixelHeight "$OUT/$shot.png" | awk '/pixel/ {print $2}' | paste -sd x -))"
  done
  xcrun simctl status_bar "$UDID" clear
done
