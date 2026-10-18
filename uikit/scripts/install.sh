#!/usr/bin/env bash
# Copy the ui module and the examples the app ships into the app (the app's
# copies are generated; edit them here).
set -euo pipefail
cd "$(dirname "$0")/.."
APP=../app/web
cp python/ui.py "$APP/public/runtime/python/ui.py"
for name in "Todo App" Paint Bounce Navigation Tabs Settings "Async Data"; do
  cp "examples/$name.py" "$APP/public/examples/$name.py"
done
echo "installed ui.py and the examples into app/web (the app renders natively, D30)"
