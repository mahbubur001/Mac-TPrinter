#!/usr/bin/env bash
# Regenerates Support/AppIcon.icns from scripts/make-icon.swift. Run after changing the icon drawing.
set -euo pipefail
cd "$(dirname "$0")/.."
export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk}"
tmp="$(mktemp -d)"
swift scripts/make-icon.swift "$tmp/icon1024.png" >/dev/null
set_dir="$tmp/AppIcon.iconset"
mkdir -p "$set_dir"
for size in 16 32 128 256 512; do
    sips -z $size $size "$tmp/icon1024.png" --out "$set_dir/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$tmp/icon1024.png" --out "$set_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o Support/AppIcon.icns
rm -rf "$tmp"
echo "Wrote Support/AppIcon.icns"
