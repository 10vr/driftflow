#!/bin/bash
# Releases Driftflow for Mac (Apple Silicon, macOS 15+) and hands it to everyone's auto-updater.
#
#   ./release.sh 0.2.0 [--notes "What changed"]   build, sign, publish to GitHub Releases (tag mac-v0.2.0)
#                                                 and add it to the update feed, updates/macos/appcast.xml
#   ./release.sh 0.2.0 --local                    only build dist/Driftflow-0.2.0.zip
#
# Signing: with a "Developer ID Application" certificate in your keychain the app is signed with it
# and notarized by Apple (store the notary login once with
# `xcrun notarytool store-credentials driftflow-notary --apple-id … --team-id …`). Otherwise it is
# signed with the free "Driftflow Dev" certificate: updates keep working and keep their Microphone
# and Accessibility permissions, but a first install needs right-click › Open.
#
# Updates are signed with the Sparkle key in your keychain (account "driftflow"); the app refuses
# any update that isn't. Keep a backup of that key and of the certificate: see README.md.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version> [--notes \"…\"] [--local]}"
shift
NOTES="" LOCAL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --notes) NOTES="${2:?--notes needs text}"; shift 2 ;;
        --local) LOCAL=1; shift ;;
        *) echo "Unknown option $1" >&2; exit 2 ;;
    esac
done

REPO="10vr/driftflow"
TAG="mac-v$VERSION"
APP="build.noindex/Driftflow.app"
DIST="dist"
ZIP="$DIST/Driftflow-$VERSION.zip"
FEED="../updates/macos/appcast.xml"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
BUILD_NUMBER="$(date +%Y%m%d%H%M)" # Sparkle compares this; it only ever goes up

if [ "$LOCAL" = 0 ]; then
    export GH_TOKEN="${GH_TOKEN:-$(gh auth token -u "${REPO%%/*}" 2>/dev/null || gh auth token)}"
    if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
        echo "Release $TAG already exists. Use a new version number." >&2; exit 1
    fi
    if [ -n "$(git status --porcelain -- "$FEED")" ]; then
        echo "$FEED has uncommitted changes; commit or discard them first." >&2; exit 1
    fi
fi

./build.sh >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

DEVELOPER_ID="${DEVELOPER_ID:-$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)}"
IDENTITY="${DEVELOPER_ID:-Driftflow Dev}"
security find-certificate -c "${IDENTITY#Developer ID Application: }" >/dev/null 2>&1 || {
    echo "No signing certificate \"$IDENTITY\" in your keychain (see README.md › Releasing)." >&2; exit 1
}
TIMESTAMP=()
if [ -n "$DEVELOPER_ID" ]; then TIMESTAMP=(--timestamp); fi
# Changing Info.plist broke the app's signature: sign it again (Sparkle inside is already signed).
codesign --force --options runtime --entitlements Resources/Driftflow.entitlements \
    --identifier dev.driftflow.app ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p "$DIST"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
if [ -n "$DEVELOPER_ID" ]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "${NOTARY_PROFILE:-driftflow-notary}" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi
echo "Created $ZIP (signed as \"$IDENTITY\")"
[ "$LOCAL" = 1 ] && exit 0

# sign_update prints: sparkle:edSignature="…" length="…"
SIGNATURE="$("$SPARKLE_BIN/sign_update" --account driftflow "$ZIP")"
URL="https://github.com/$REPO/releases/download/$TAG/Driftflow-$VERSION.zip"

INSTALL_NOTES="**Install:** download Driftflow-$VERSION.zip, unzip it and drag Driftflow into Applications."
if [ -z "$DEVELOPER_ID" ]; then
    INSTALL_NOTES="$INSTALL_NOTES The first time, right-click Driftflow › Open (or System Settings › Privacy & Security › Open Anyway), because it isn't signed with an Apple Developer ID."
fi
INSTALL_NOTES="$INSTALL_NOTES Already installed? Driftflow updates itself."
gh release create "$TAG" "$ZIP" -R "$REPO" --title "Driftflow for Mac $VERSION" \
    --notes "${NOTES:+$NOTES

}$INSTALL_NOTES"

python3 - "$FEED" "$VERSION" "$BUILD_NUMBER" "$URL" "$SIGNATURE" "$NOTES" <<'PY'
import sys, html, email.utils, pathlib
feed, version, build, url, signature, notes = sys.argv[1:]
path = pathlib.Path(feed)
text = path.read_text()
notes_html = "".join(f"<p>{html.escape(line)}</p>" for line in notes.splitlines() if line.strip()) or f"<p>Driftflow {html.escape(version)}</p>"
item = f"""        <item>
            <title>Driftflow {version}</title>
            <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
            <description><![CDATA[{notes_html}]]></description>
            <enclosure url="{url}" type="application/octet-stream" {signature.strip()}/>
        </item>
"""
marker = "        <!-- releases, newest first -->\n"
assert marker in text, "appcast marker missing"
path.write_text(text.replace(marker, marker + item, 1))
PY

git add "$FEED"
git commit -q -m "Mac $VERSION: add to the update feed"
git push -q
echo "Published $TAG. Macs running Driftflow pick it up within a day (or at once via Check for Updates…)."
