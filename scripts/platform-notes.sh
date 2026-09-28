#!/bin/bash
# Prints the release notes one platform's updater should show. In the notes, a line starting
# "Mac:" is for Mac only and "Windows:" for Windows only (the prefix is dropped); other lines are
# for both. Prints nothing if the release has no changes for that platform, and then that
# platform isn't offered the update.
#   scripts/platform-notes.sh mac "$NOTES"
PLATFORM="${1:?usage: platform-notes.sh mac|windows <notes>}"
case "$PLATFORM" in
    mac) KEEP="Mac" DROP="Windows" ;;
    windows) KEEP="Windows" DROP="Mac" ;;
    *) echo "platform must be mac or windows" >&2; exit 2 ;;
esac
printf '%s\n' "${2:-}" | while IFS= read -r line; do
    case "$line" in
        "$DROP:"*) ;;
        "$KEEP:"*) line="${line#"$KEEP:"}"; printf '%s\n' "${line# }" ;;
        *[![:space:]]*) printf '%s\n' "$line" ;;
    esac
done
