#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
BUILD_DIR="$SCRIPT_DIR/.build"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

echo "=== Installing wx2ai Applications ==="

# Target /Applications with fallback to ~/Applications
TARGET_APPS_DIR="/Applications"
if [ ! -w "/Applications" ]; then
    echo "Notice: /Applications is not writable. Installing to ~/Applications instead."
    TARGET_APPS_DIR="$HOME/Applications"
fi

mkdir -p "$TARGET_APPS_DIR"
echo "Target directory: $TARGET_APPS_DIR"

# 1. Clean existing app bundles
echo "--> Copying applications to $TARGET_APPS_DIR..."
rm -rf "$TARGET_APPS_DIR/WeChatToAntigravity.app" \
       "$TARGET_APPS_DIR/WeChatToCodex.app" \
       "$TARGET_APPS_DIR/WeChatToClipboard.app"

cp -R "$DIST_DIR/WeChatToAntigravity.app" "$TARGET_APPS_DIR/"
cp -R "$DIST_DIR/WeChatToCodex.app" "$TARGET_APPS_DIR/"
cp -R "$DIST_DIR/WeChatToClipboard.app" "$TARGET_APPS_DIR/"

# 2. Register with LaunchServices (lsregister -f)
if [ -f "$LSREGISTER" ]; then
    echo "--> Registering with LaunchServices..."
    "$LSREGISTER" -f "$TARGET_APPS_DIR/WeChatToAntigravity.app"
    "$LSREGISTER" -f "$TARGET_APPS_DIR/WeChatToCodex.app"
    "$LSREGISTER" -f "$TARGET_APPS_DIR/WeChatToClipboard.app"
else
    echo "Warning: lsregister not found at $LSREGISTER"
fi

# 3. Add App Extensions with pluginkit -a
echo "--> Registering App Extensions with pluginkit..."
/usr/bin/pluginkit -a "$TARGET_APPS_DIR/WeChatToAntigravity.app/Contents/PlugIns/WechatShare.appex"
/usr/bin/pluginkit -a "$TARGET_APPS_DIR/WeChatToCodex.app/Contents/PlugIns/WechatShare.appex"
/usr/bin/pluginkit -a "$TARGET_APPS_DIR/WeChatToClipboard.app/Contents/PlugIns/WechatShare.appex"

# 4. Enable App Extensions with pluginkit -e use -i <bundle_id>
echo "--> Enabling App Extensions..."
/usr/bin/pluginkit -e use -i io.github.bilppppp.wx2ai.antigravity.WechatShare || true
/usr/bin/pluginkit -e use -i io.github.bilppppp.wx2ai.codex.WechatShare || true
/usr/bin/pluginkit -e use -i io.github.bilppppp.wx2ai.clipboard.WechatShare || true

# 5. Check active NSSharingServices for .zip files
if [ -x "$BUILD_DIR/check_share_services" ]; then
    echo ""
    echo "--> Checking available NSSharingServices for .zip..."
    "$BUILD_DIR/check_share_services"
fi

echo ""
echo "=== Installation Completed Successfully ==="
