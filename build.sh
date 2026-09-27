#!/bin/bash
# Builds Driftflow.app (arm64, release) into ./build and ad-hoc signs it.
set -euo pipefail
cd "$(dirname "$0")"

# Usage: ./build.sh [--install]   (--install copies the app to /Applications and relaunches it)
INSTALL=0
if [ "${1:-}" = "--install" ]; then INSTALL=1; shift; fi
CONFIG="${1:-release}"
swift build -c "$CONFIG" --arch arm64
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

APP="build.noindex/Driftflow.app" # .noindex keeps Spotlight/Launchpad from listing a second copy
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Driftflow" "$APP/Contents/MacOS/Driftflow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Sounds/*.caf Resources/Sounds/*.wav Resources/Sounds/THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

# Sign with a stable identity when available so macOS keeps the Accessibility grant across rebuilds.
# Create one once: Keychain Access › Certificate Assistant › Create a Certificate…
#   Name: Driftflow Dev · Identity Type: Self Signed Root · Certificate Type: Code Signing
IDENTITY="${MURMUR_SIGN_IDENTITY:-Driftflow Dev}"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    # Hardened runtime + mic entitlement: the same signature shape as shared/notarized builds.
    codesign --force --options runtime --entitlements Resources/Driftflow.entitlements \
        --sign "$IDENTITY" --identifier dev.driftflow.app "$APP"
    echo "Built $APP (signed as \"$IDENTITY\")"
else
    codesign --force --sign - --identifier dev.driftflow.app "$APP"
    echo "Built $APP (ad hoc: re-grant Accessibility after each rebuild)"
fi

if [ "$INSTALL" = 1 ]; then
    pkill -x Driftflow 2>/dev/null || true
    rm -rf /Applications/Driftflow.app
    cp -R "$APP" /Applications/Driftflow.app
    # Refresh Launchpad/Spotlight's record of the app and its icon.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Driftflow.app
    open /Applications/Driftflow.app
    echo "Installed /Applications/Driftflow.app"
fi
