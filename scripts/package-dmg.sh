#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$PROJECT_ROOT/scripts/build-demo.sh"
APP_PATH="$PROJECT_ROOT/build/Reset Radar.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
ARCH="$(lipo -archs "$APP_PATH/Contents/MacOS/ResetRadar" | tr ' ' '-')"
DIST_DIR="$PROJECT_ROOT/dist"
DMG_NAME="Reset-Radar-${VERSION}-macOS-${ARCH}.dmg"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reset-radar-dmg.XXXXXX")"
MOUNT_PATH="$WORK_DIR/mounted"
ATTACHED=0
cleanup() {
    if (( ATTACHED )); then
        hdiutil detach "$MOUNT_PATH" >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$DIST_DIR" "$WORK_DIR/staging" "$MOUNT_PATH" "$WORK_DIR/install-check"
ditto "$APP_PATH" "$WORK_DIR/staging/Reset Radar.app"
ln -s /Applications "$WORK_DIR/staging/Applications"
cat > "$WORK_DIR/staging/Read Me.txt" <<'INSTALL'
Reset Radar · macOS

1. Drag Reset Radar.app into Applications.
2. Launch the app and click its menu bar icon.
3. Open Settings to configure your AI provider URL, key and model.
4. English is the default language. Choose 简体中文 in Settings → Language if desired.

Requires Apple Silicon and macOS 14+. macOS 26 uses native Liquid Glass.
Ad-hoc signed; not Apple notarized. External downloads may require confirmation
in System Settings → Privacy & Security. No personal keys or local caches are included.
AI probabilities are uncalibrated estimates, not personal account reset guarantees.

中文安装说明

1. 将 Reset Radar.app 拖到旁边的 Applications（应用程序）文件夹。
2. 从“应用程序”打开 Reset Radar。
3. 应用常驻屏幕顶部菜单栏，点击概率图标打开主面板。
4. 在设置中配置自己的 AI 服务 URL、Key 和模型。

要求：Apple Silicon（M 系列芯片），macOS 14 或以上。
macOS 26 使用原生 Liquid Glass，旧系统使用系统模糊材质。

这是本地开发签名版本，尚未经过 Apple Developer ID 签名和公证。
在其他 Mac 上首次打开时，macOS 可能要求通过“系统设置 → 隐私与安全性”确认打开。

安装包不包含个人 API Key、账号配置或本机帖子分析缓存。
历史记录是随应用提供的公开社区归档，AI 概率为未经校准的估计。
INSTALL

codesign --verify --deep --strict "$WORK_DIR/staging/Reset Radar.app"
hdiutil create -srcfolder "$WORK_DIR/staging" -volname 'Reset Radar' \
    -fs HFS+ -format UDZO -ov "$DIST_DIR/$DMG_NAME"
hdiutil verify "$DIST_DIR/$DMG_NAME"
ATTACHED=1
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_PATH" "$DIST_DIR/$DMG_NAME"
test "$(readlink "$MOUNT_PATH/Applications")" = /Applications
codesign --verify --deep --strict "$MOUNT_PATH/Reset Radar.app"

# Verify the drag-copy result in a temporary folder, without changing /Applications.
ditto "$MOUNT_PATH/Reset Radar.app" "$WORK_DIR/install-check/Reset Radar.app"
codesign --verify --deep --strict "$WORK_DIR/install-check/Reset Radar.app"
"$WORK_DIR/install-check/Reset Radar.app/Contents/MacOS/ResetRadar" --check-native-window
hdiutil detach "$MOUNT_PATH"
ATTACHED=0
(
    cd "$DIST_DIR"
    shasum -a256 "$DMG_NAME" > "$DMG_NAME.sha256"
)
echo "$DIST_DIR/$DMG_NAME"
