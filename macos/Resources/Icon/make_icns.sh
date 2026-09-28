#!/bin/bash
# Regenerates Resources/AppIcon.icns from render_icon.swift (all macOS sizes, rendered natively
# at each resolution rather than downscaled, so small sizes stay sharp).
set -euo pipefail
cd "$(dirname "$0")"
TMP="$(mktemp -d)"
swiftc -O render_icon.swift -o "$TMP/render"
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
    "$TMP/render" "$SET/icon_${size}x${size}.png" "$size"
    "$TMP/render" "$SET/icon_${size}x${size}@2x.png" "$((size * 2))"
done
iconutil -c icns "$SET" -o ../AppIcon.icns
"$TMP/render" icon_1024.png 1024
rm -rf "$TMP"
echo "Wrote Resources/AppIcon.icns"
