#!/bin/bash
# Build the App Store archive and export it; --upload sends it to App Store
# Connect (TestFlight, then review). D51; the checklist is app/appstore/README.md.
#
#   scripts/archive.sh            build/Terrarium.xcarchive and build/export/Terrarium.ipa
#   scripts/archive.sh --upload   the same, uploaded instead of exported
#
# Signing is automatic with the project's team; the first export creates the
# distribution certificate if the account has none. Uploads use the Xcode
# account, or an App Store Connect API key: ASC_KEY_ID, ASC_ISSUER_ID and
# ASC_KEY_PATH (the .p8 file).
#
# BUILD_NUMBER sets CFBundleVersion (default: the UTC time, YYYYMMDD.HHMM, so
# every upload has a higher one). The version (CFBundleShortVersionString) is
# MARKETING_VERSION in the project.
set -euo pipefail
cd "$(dirname "$0")/.."

UPLOAD=0
for arg in "$@"; do
  case "$arg" in
    --upload) UPLOAD=1 ;;
    *) echo "unknown argument $arg" >&2; exit 2 ;;
  esac
done

BUILD_NUMBER=${BUILD_NUMBER:-$(date -u +%Y%m%d.%H%M)}
ARCHIVE=build/Terrarium.xcarchive
EXPORT=build/export
mkdir -p build

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  echo "warning: the working tree has uncommitted changes" >&2
fi

./scripts/fetch-pyodide.sh
./scripts/build-docs.py
./scripts/build-ty.sh
(cd web && { [ -d node_modules ] || npm install --silent; } && npm run build --silent > ../build/vite.log 2>&1) \
  || { cat build/vite.log; exit 1; }

# Release without SELFTEST_SPI: the self-test's private-API hooks are not compiled in.
echo "archiving build $BUILD_NUMBER"
rm -rf "$ARCHIVE"
xcodebuild -project ios/Terrarium.xcodeproj -scheme Terrarium -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$ARCHIVE" -derivedDataPath build/dd-archive \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD_NUMBER" archive > build/archive.log 2>&1 \
  || { grep -E "error:" build/archive.log | head -20; tail -5 build/archive.log; exit 1; }

# What review needs to find in the bundle, and what it must not.
APP="$ARCHIVE/Products/Applications/Terrarium.app"
for f in PrivacyInfo.xcprivacy web/licenses.json web/runtimes.json web/engine.html; do
  [ -e "$APP/$f" ] || { echo "error: $f is missing from the app" >&2; exit 1; }
done
if strings "$APP/Terrarium" | grep -qE '_killWebContentProcess|UIKeyboardImpl|addInputString:'; then
  echo "error: the self-test's private-API hooks are in the binary (SELFTEST_SPI set?)" >&2
  exit 1
fi
if find "$APP" -name "*.map" | grep -q .; then
  echo "error: source maps in the bundle" >&2
  exit 1
fi
echo "archive: $ARCHIVE ($(du -sh "$APP" | cut -f1) app, version $(plutil -extract CFBundleShortVersionString raw "$APP/Info.plist") ($BUILD_NUMBER))"

OPTIONS=build/ExportOptions.plist
cp ios/ExportOptions.plist "$OPTIONS"
[ "$UPLOAD" = 1 ] && plutil -replace destination -string upload "$OPTIONS"
AUTH=()
if [ -n "${ASC_KEY_ID:-}" ]; then
  AUTH=(-authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -authenticationKeyPath "$ASC_KEY_PATH")
fi
rm -rf "$EXPORT"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$OPTIONS" \
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} > build/export.log 2>&1 \
  || { grep -E "error" build/export.log | head -20; tail -5 build/export.log; exit 1; }
if [ "$UPLOAD" = 1 ]; then
  echo "uploaded build $BUILD_NUMBER; it shows up in App Store Connect (TestFlight) after processing"
else
  echo "exported: $EXPORT/Terrarium.ipa"
fi
