#!/bin/bash
# Packages Driftflow for other Macs (Apple Silicon, macOS 15+).
#
#   ./release.sh 1.0.0 --quick   dist/Driftflow-1.0.0.zip, signed with the local "Driftflow Dev" certificate.
#                                Colleagues open it once via System Settings › Privacy & Security › Open Anyway.
#   ./release.sh 1.0.0           dist/Driftflow-1.0.0.dmg, signed with your Developer ID and notarized by
#                                Apple, so it opens with no warnings. One-time setup:
#                                  1. Apple Developer Program → create a "Developer ID Application" certificate.
#                                  2. xcrun notarytool store-credentials driftflow-notary \
#                                       --apple-id you@example.com --team-id TEAMID   (uses an app-specific password)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version> [--quick]}"
MODE="${2:-notarize}"
APP="build.noindex/Driftflow.app"
DIST="dist"
mkdir -p "$DIST"

./build.sh >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"

sign() { # identity, extra args…
    codesign --force --options runtime --entitlements Resources/Driftflow.entitlements \
        --identifier dev.driftflow.app --sign "$@" "$APP"
    codesign --verify --strict --verbose=1 "$APP"
}

if [ "$MODE" = "--quick" ]; then
    IDENTITY="Driftflow Dev"
    if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then sign "$IDENTITY"; else sign -; fi
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    cat > "$STAGE/How to open Driftflow.txt" <<TXT
Driftflow $VERSION: on-device dictation for Apple Silicon Macs (macOS 26 or later).

1. Drag Driftflow.app into your Applications folder.
2. Open it. macOS will say it can't verify the developer. Click Done.
3. Open System Settings › Privacy & Security, scroll down and click "Open Anyway" next to Driftflow.
4. Follow the setup window: allow Microphone and Accessibility.
   The speech model (~590 MB) downloads once on first launch.

Hold Right ⌘ to dictate, release to insert. Tap it once for hands-free.
TXT
    rm -f "$DIST/Driftflow-$VERSION.zip"
    ditto -c -k --sequesterRsrc "$STAGE" "$DIST/Driftflow-$VERSION.zip"
    rm -rf "$STAGE"
    echo "Created $DIST/Driftflow-$VERSION.zip"
    exit 0
fi

DEVELOPER_ID="${DEVELOPER_ID:-$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}"
if [ -z "$DEVELOPER_ID" ]; then
    echo "No \"Developer ID Application\" certificate in your keychain. See the setup notes at the top of release.sh," >&2
    echo "or run ./release.sh $VERSION --quick for a zip your colleagues open via Privacy & Security." >&2
    exit 1
fi
sign "$DEVELOPER_ID" --timestamp

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/Driftflow-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Driftflow" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "${NOTARY_PROFILE:-driftflow-notary}" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
echo "Created $DMG (notarized)"
