#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$PROJECT_ROOT/apps/macos" -c release
BIN_DIR="$(swift build --package-path "$PROJECT_ROOT/apps/macos" -c release --show-bin-path)"
APP_DIR="$PROJECT_ROOT/build/Reset Radar.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_DIR/ResetRadar" "$APP_DIR/Contents/MacOS/ResetRadar"
mkdir -p "$APP_DIR/Contents/Resources"
cp -R "$BIN_DIR/ResetRadar_ResetRadar.bundle" "$APP_DIR/Contents/Resources/"
cp -R "$BIN_DIR/RadarCore_RadarCore.bundle" "$APP_DIR/Contents/Resources/"
cp "$PROJECT_ROOT/apps/macos/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$PROJECT_ROOT/LICENSE" "$APP_DIR/Contents/Resources/LICENSE.txt"
cp "$PROJECT_ROOT/data/LICENSE-DATA.md" "$APP_DIR/Contents/Resources/THIRD-PARTY-DATA.md"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>CFBundleIdentifier</key><string>local.resetradar.demo</string>
<key>CFBundleName</key><string>Reset Radar</string>
<key>CFBundleExecutable</key><string>ResetRadar</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.1</string>
<key>CFBundleVersion</key><string>8</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR"
echo "$APP_DIR"
