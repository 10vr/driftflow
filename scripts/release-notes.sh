#!/bin/bash
# Prints the text of Driftflow's GitHub release page for one version: what changed, then how to
# install it. Used by macos/release.sh. (Add the Windows instructions when the new Windows app ships.)
#   scripts/release-notes.sh 0.2.2 "What changed"
VERSION="${1:?usage: release-notes.sh <version> [notes]}"
NOTES="${2:-}"
cat <<TEXT
${NOTES:+$NOTES

}## Install

**Mac** (Apple Silicon, macOS 15 or later): download **Driftflow-$VERSION-macOS.dmg**, open it and drag Driftflow onto Applications. The first time, right-click Driftflow in Applications › Open, because it isn't signed with an Apple Developer ID yet. (The .zip is what installed copies update from.)

Already installed? Driftflow updates itself.
TEXT
