#!/bin/bash
# Prints the text of Driftflow's GitHub release page for one version: what changed, then how to
# install it on each platform. Used by macos/release.sh and the Windows build, whichever creates
# the release first.
#   scripts/release-notes.sh 0.2.2 "What changed"
VERSION="${1:?usage: release-notes.sh <version> [notes]}"
NOTES="${2:-}"
cat <<TEXT
${NOTES:+$NOTES

}## Install

**Mac** (Apple Silicon, macOS 15 or later): download **Driftflow-$VERSION-macOS.dmg**, open it and drag Driftflow onto Applications. The first time, right-click Driftflow in Applications › Open, because it isn't signed with an Apple Developer ID yet. (The .zip is what installed copies update from.)

**Windows** (10 or 11, 64-bit): download **Driftflow-$VERSION-Windows-x64-setup.exe** and run it. If Windows says "Windows protected your PC", click More info › Run anyway.

Already installed? Driftflow updates itself.
TEXT
