#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICON_SOURCE="$PROJECT_ROOT/docs/brand/logo.png"
ICON_WORK="$(mktemp -d "${TMPDIR:-/tmp}/reset-radar-icon.XXXXXX")"
trap 'rm -rf "$ICON_WORK"' EXIT
mkdir -p "$ICON_WORK/AppIcon.iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICON_WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_SOURCE" --out "$ICON_WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$PROJECT_ROOT/apps/macos/Resources/AppIcon.icns"
echo 'Updated apps/macos/Resources/AppIcon.icns'
