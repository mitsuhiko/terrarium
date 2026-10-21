#!/bin/bash
# Download the pinned Pyodide cores listed in runtimes.json into app/vendor
# (gitignored): vendor/pyodide-<pyodide version>.
#
# App Store compliance (D57): urllib.parse lists the itms-services scheme, and
# App Review rejects apps that contain the string (guideline 2.5.2). CPython
# removes it on iOS (--with-app-store-compliance); Pyodide's Emscripten
# builds keep it, so it is taken out of each core's python_stdlib.zip here.
set -euo pipefail
cd "$(dirname "$0")/.."

comply() {
  local zip="$PWD/$1/python_stdlib.zip" tmp
  unzip -p "$zip" | grep -ac itms-services >/dev/null || return 0
  tmp=$(mktemp -d)
  unzip -q "$zip" urllib/parse.py -d "$tmp"
  sed -i '' "s/, 'itms-services'\]/]/" "$tmp/urllib/parse.py"
  (cd "$tmp" && zip -q -X "$zip" urllib/parse.py)
  rm -rf "$tmp"
  if unzip -p "$zip" | grep -ac itms-services >/dev/null; then
    echo "error: $zip still has itms-services; see App Store compliance in $0" >&2
    exit 1
  fi
  echo "removed itms-services from $1/python_stdlib.zip"
}

for spec in $(node -e 'for (const r of require("./runtimes.json").runtimes) console.log(`${r.pyodide}:${r.version}`)'); do
  VERSION=${spec%%:*}
  PYTHON=${spec#*:}
  DEST=vendor/pyodide-$VERSION
  [ -d "$DEST" ] && { comply "$DEST"; continue; }
  mkdir -p vendor
  TMP=$(mktemp -d)
  (cd "$TMP" && npm pack --loglevel=error "pyodide@$VERSION" >/dev/null && tar xzf "pyodide-$VERSION.tgz")
  # runtimes.json states the Python version; it must be the one the core has.
  HAS=$(node -e "console.log(require('$TMP/package/pyodide-lock.json').info.python)")
  [ "$HAS" = "$PYTHON" ] || { echo "error: Pyodide $VERSION has Python $HAS, runtimes.json says $PYTHON" >&2; exit 1; }
  mv "$TMP/package" "$DEST"
  rm -rf "$TMP"
  echo "fetched Pyodide $VERSION (Python $PYTHON) into $DEST"
  comply "$DEST"
done
