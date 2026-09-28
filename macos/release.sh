#!/bin/bash
# Releases a Driftflow version for Mac and Windows together, on one GitHub release page
# ("Driftflow 0.2.2", tag v0.2.2), and hands it to everyone's auto-updater.
#
#   ./release.sh 0.2.2 --notes "What changed"   tags v0.2.2 and pushes the tag, which makes GitHub
#                                               build Windows and add its installer to the page;
#                                               then builds and signs the Mac app, adds
#                                               Driftflow-0.2.2-macOS.zip to the page and lists
#                                               it in the Mac update feed, updates/macos/appcast.xml
#   ./release.sh 0.2.2 --local                  only build dist/Driftflow-0.2.2-macOS.zip
#
# The tag goes on the commit you're on, which must be pushed and clean. If the tag already exists
# (you pushed it yourself), its message is used as the notes.
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
TAG="v$VERSION"
APP="build.noindex/Driftflow.app"
DIST="dist"
ZIP_NAME="Driftflow-$VERSION-macOS.zip"
ZIP="$DIST/$ZIP_NAME"
FEED="../updates/macos/appcast.xml"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
BUILD_NUMBER="$(date +%Y%m%d%H%M)" # Sparkle compares this; it only ever goes up

if [ "$LOCAL" = 0 ]; then
    export GH_TOKEN="${GH_TOKEN:-$(gh auth token -u "${REPO%%/*}" 2>/dev/null || gh auth token)}"
    if gh release view "$TAG" -R "$REPO" --json assets --jq '.assets[].name' 2>/dev/null | grep -qx "$ZIP_NAME"; then
        echo "The $TAG release already has $ZIP_NAME. Use a new version number." >&2; exit 1
    fi
    git fetch -q origin main --tags
    if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
        # Tagged already (by hand): its message is the release notes.
        [ -n "$NOTES" ] || NOTES="$(git tag -l --format='%(contents)' "$TAG" | sed '/-----BEGIN/,$d')"
    else
        if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
            echo "Commit and push everything first: the tag goes on the pushed commit you're on." >&2; exit 1
        fi
        git tag -a "$TAG" -m "${NOTES:-Driftflow $VERSION}"
        git push -q origin "$TAG"
        echo "Pushed $TAG: GitHub is building Windows (about 20 minutes)."
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
URL="https://github.com/$REPO/releases/download/$TAG/$ZIP_NAME"

# One release page per version, shared with the Windows installer (the Windows build may have
# created it already; if both try at once, the loser uploads to the winner's page).
gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 \
    || gh release create "$TAG" -R "$REPO" --verify-tag --title "Driftflow $VERSION" \
        --notes "$(../scripts/release-notes.sh "$VERSION" "$NOTES")" \
    || true
gh release upload "$TAG" "$ZIP" -R "$REPO" --clobber

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
# The Windows build may have pushed its feed update meanwhile.
git pull -q --rebase origin main
git push -q origin HEAD:main
echo "Published the Mac download: https://github.com/$REPO/releases/tag/$TAG"
echo "Macs running Driftflow pick it up within a day (or at once via Check for Updates…); Windows follows when its build finishes."
