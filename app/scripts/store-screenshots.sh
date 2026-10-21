#!/bin/bash
# App Store screenshots (D51): the sizes App Store Connect asks for, from the
# simulators, with a clean status bar, into appstore/screenshots/<device>/
# (committed; the README shows them).
#
#   scripts/store-screenshots.sh              iPhone 6.9" and iPad 13"
#   scripts/store-screenshots.sh iphone       one of them
#   scripts/store-screenshots.sh duo          the iPhone Duo's inner screen (D58, D59):
#                                             open it in DeviceHub first (nothing
#                                             headless opens it), landscape
#   scripts/store-screenshots.sh iphone 3     only the scenes whose name starts with 3
#   IPHONE="iPhone 18 Pro Max" IPAD="iPad Pro 13-inch (M5)" APPEARANCE=dark ...
#
# Each scene starts from a fresh app state (settings cleared, examples
# re-seeded with --reset) and uses the launch hooks (AppModel.launchHooks).
# The simulators' Documents are wiped. The plot, the notebook and the agent
# need the network the first time (numpy and matplotlib come from Pyodide's
# CDN). The agent's scene is scripted (web/src/agent/demo.ts): its tools
# really read, edit, check and run Examples/Plot.py.
#
# The status bar shows 9:41 in the 12-hour format, so the simulator's region
# is set to en_US for the run (a reboot when it was another one) and put back
# afterwards (in effect after the simulator's next boot).
set -euo pipefail
cd "$(dirname "$0")/.."

KINDS=()
ONLY=""
for arg in "$@"; do
  case "$arg" in
    iphone|ipad|duo) KINDS+=("$arg") ;;
    *) ONLY=$arg ;;
  esac
done
[ ${#KINDS[@]} -gt 0 ] || KINDS=(iphone ipad)
IPHONE=${IPHONE:-iPhone 18 Pro Max}
IPAD=${IPAD:-iPad Pro 13-inch (M5)}
DUO=${DUO:-iPhone Duo}
APPEARANCE=${APPEARANCE:-light}
BUNDLE_ID=eu.ronacher.Terrarium

# Hello.py with a typo for ty to find, typed after the last line (%0A is a newline, @@ the cursor).
TYPO='cursor=9:1&focus&type=%0Asquares = [i * i for i in range(1, 6)]%0Aprint(nmae, "gets", sum(squares))@@'

# Todo App.py: a helper typed between two functions, with ty's completions open (iPad: no keyboard).
COMPLETION='cursor=24:1&focus&type=%0A%0Adef tomorrow() -> str:%0A    return (datetime.date.today() + datetime.timedelta(days=1)).isof@@'

# name|fragment|seconds to wait
IPHONE_SCENES=(
  "1-plot|open=Examples/Plot.py&run&pane=console|25"
  "2-agent|open=Examples/Plot.py&agent=demo|40"
  "3-editor|open=Examples/Hello.py&$TYPO|16"
  "4-notebook|open=Examples/Notebook.ipynb&cells&top=## Plots|35"
  "5-todo|open=Examples/Todo App.py&run|14"
  "6-debugger|open=Examples/Cells.py&bp=16&run&pane=console|16"
  "7-turtle|open=Examples/Turtle.py&run&pane=console|22"
  "8-docs|docs=3.14/library/json.html|8"
  "9-files|folder=Examples|10"
)
IPAD_SCENES=(
  "1-split|open=Examples/Turtle.py&split=Examples/Plot.py&run&folder=Examples|25"
  "2-agent|open=Examples/Plot.py&folder=Examples&agent=demo|40"
  "3-notebook|open=Examples/Notebook.ipynb&folder=Examples&cells&top=## Plots&pane=editor|35"
  "4-editor|open=Examples/Todo App.py&folder=Examples&pane=editor&$COMPLETION|16"
  "5-debugger|open=Examples/Cells.py&folder=Examples&bp=16&run|16"
  "6-todo|open=Examples/Todo App.py&panel=app&sidebar=0&run|14"
  "7-docs|docs=3.14/library/json.html|8"
)
# The open iPhone Duo: the halves on either side of the fold (D59).
DUO_SCENES=(
  "1-app|open=Examples/Todo App.py&panel=app&sidebar=0&run|14"
  "2-agent|open=Examples/Plot.py&panel=agent&sidebar=0&agent=demo|40"
  "3-plot|open=Examples/Plot.py&panel=console&sidebar=0&run|25"
  "4-docs|open=Examples/Hello.py&panel=docs&side=first&sidebar=0&docs=3.14/library/json.html|10"
  "5-split|open=Examples/Turtle.py&split=Examples/Plot.py&sidebar=0&pane=editor|12"
  "6-files|open=Examples/Todo App.py&folder=Examples&panel=console|10"
)

running() { xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -q "UIKitApplication:$BUNDLE_ID\["; }

for kind in "${KINDS[@]}"; do
  case "$kind" in
    iphone) NAME=$IPHONE; SCENES=("${IPHONE_SCENES[@]}"); SCREEN=() ;;
    ipad) NAME=$IPAD; SCENES=("${IPAD_SCENES[@]}"); SCREEN=() ;;
    duo) NAME=$DUO; SCENES=("${DUO_SCENES[@]}"); SCREEN=(--display=3) ;;   # the inner screen
  esac
  UDID=$(./scripts/simulator.sh "$kind" "$NAME")
  echo "$kind: $NAME ($UDID)"
  LOCALE=$(xcrun simctl spawn "$UDID" defaults read -g AppleLocale 2>/dev/null || true)
  # A reboot would fold the Duo again (it boots closed): its locale stays.
  [ "$kind" != duo ] || LOCALE=en_US
  if [ "$LOCALE" != en_US ]; then
    xcrun simctl spawn "$UDID" defaults write -g AppleLocale en_US
    xcrun simctl shutdown "$UDID"
    xcrun simctl boot "$UDID"
    xcrun simctl bootstatus "$UDID" > /dev/null
  fi
  SIM=$UDID ./run.sh   # build, install and launch once
  xcrun simctl ui "$UDID" appearance "$APPEARANCE"
  xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  OUT=appstore/screenshots/$kind
  [ -n "$ONLY" ] || rm -rf "$OUT"   # scenes that were renamed or dropped
  mkdir -p "$OUT"
  for scene in "${SCENES[@]}"; do
    IFS='|' read -r shot fragment wait <<< "$scene"
    [ -z "$ONLY" ] || [[ "$shot" == "$ONLY"* ]] || continue
    # terminate returns before the app is gone; a launch then may not start a new one.
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    for _ in $(seq 1 50); do running || break; sleep 0.2; done
    # The app's defaults are in its container (the bundle ID alone is not found there).
    PREFS="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)/Library/Preferences/$BUNDLE_ID"
    xcrun simctl spawn "$UDID" defaults delete "$PREFS" 2>/dev/null || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID" --reset --fragment "$fragment" > /dev/null
    sleep "$wait"
    rm -f "$OUT/$shot.png"
    xcrun simctl io "$UDID" screenshot ${SCREEN[@]+"${SCREEN[@]}"} "$OUT/$shot.png" > /dev/null 2>&1
    for _ in $(seq 1 50); do [ -s "$OUT/$shot.png" ] && break; sleep 0.2; done   # written a moment later
    echo "  $OUT/$shot.png ($(sips -g pixelWidth -g pixelHeight "$OUT/$shot.png" | awk '/pixel/ {print $2}' | paste -sd x -))"
  done
  xcrun simctl status_bar "$UDID" clear
  if [ "$LOCALE" != en_US ]; then
    if [ -n "$LOCALE" ]; then xcrun simctl spawn "$UDID" defaults write -g AppleLocale "$LOCALE"
    else xcrun simctl spawn "$UDID" defaults delete -g AppleLocale; fi
  fi
done
