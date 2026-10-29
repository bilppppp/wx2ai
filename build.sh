#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"
DIST_DIR="$SCRIPT_DIR/dist"
CONFIG_DIR="$SCRIPT_DIR/Config"
ENTITLEMENTS="$CONFIG_DIR/ShareExtension.entitlements"

echo "=== Building wx2ai Bridge Applications ==="
echo "Project root: $SCRIPT_DIR"

mkdir -p "$BUILD_DIR"
mkdir -p "$DIST_DIR"

# 1. Compile Share Extension binary
echo "--> Compiling Share Extension binary..."
xcrun swiftc \
    -O \
    -target arm64-apple-macos14.0 \
    "$SCRIPT_DIR/Sources/ShareExtension/ShareViewController.swift" \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$BUILD_DIR/WechatShare"

# 2. Compile Host App binary
echo "--> Compiling Host App binary..."
xcrun swiftc \
    -O \
    -target arm64-apple-macos14.0 \
    "$SCRIPT_DIR/Sources/HostApp/main.swift" \
    -o "$BUILD_DIR/HostApp"

# 3. Compile check_share_services helper if source exists
if [ -f "$SCRIPT_DIR/Sources/check_share_services.swift" ]; then
    echo "--> Compiling check_share_services helper..."
    xcrun swiftc \
        -O \
        -target arm64-apple-macos14.0 \
        "$SCRIPT_DIR/Sources/check_share_services.swift" \
        -o "$BUILD_DIR/check_share_services"
fi

# Standard NSExtensionActivationRule predicate matching exactly 1 public.zip-archive item
ACTIVATION_RULE='SUBQUERY (extensionItems, $extensionItem, SUBQUERY ($extensionItem.attachments, $attachment, ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.zip-archive").@count == 1).@count == 1'

build_app() {
    local APP_NAME="$1"
    local HOST_BUNDLE_ID="$2"
    local TARGET_APP_NAME="$3"
    local TARGET_BUNDLE_ID="$4"
    local TARGET_FALLBACK_PATH="$5"
    local ICON_SRC="$6"
    local ICON_NAME="$7"
    local AUTO_PASTE_MODE="${8:-keystroke}"

    local APP_DIR="$DIST_DIR/$APP_NAME.app"
    local APPEX_DIR="$APP_DIR/Contents/PlugIns/WechatShare.appex"
    local APPEX_BUNDLE_ID="${HOST_BUNDLE_ID}.WechatShare"

    echo "----------------------------------------"
    echo "Assembling $APP_NAME.app"
    echo "  Host Bundle ID:      $HOST_BUNDLE_ID"
    echo "  Extension Bundle ID: $APPEX_BUNDLE_ID"
    echo "  Target App:          $TARGET_APP_NAME ($TARGET_BUNDLE_ID)"
    echo "  Auto Paste Mode:     $AUTO_PASTE_MODE"
    echo "----------------------------------------"

    rm -rf "$APP_DIR"
    mkdir -p "$APP_DIR/Contents/MacOS"
    mkdir -p "$APP_DIR/Contents/Resources"
    mkdir -p "$APPEX_DIR/Contents/MacOS"
    mkdir -p "$APPEX_DIR/Contents/Resources"

    # Copy executables
    cp "$BUILD_DIR/HostApp" "$APP_DIR/Contents/MacOS/$APP_NAME"
    chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"
    cp "$BUILD_DIR/WechatShare" "$APPEX_DIR/Contents/MacOS/WechatShare"
    chmod +x "$APPEX_DIR/Contents/MacOS/WechatShare"

    # Copy Icons to both Host App and Extension (fallback to macOS generic icon if missing)
    local DEFAULT_FALLBACK_ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns"
    local EFFECTIVE_ICON_SRC="$ICON_SRC"
    if [ ! -f "$EFFECTIVE_ICON_SRC" ]; then
        if [ -f "$DEFAULT_FALLBACK_ICON" ]; then
            EFFECTIVE_ICON_SRC="$DEFAULT_FALLBACK_ICON"
            echo "  Notice: Local icon not found at $ICON_SRC, using system fallback ($DEFAULT_FALLBACK_ICON)"
        fi
    fi

    if [ -f "$EFFECTIVE_ICON_SRC" ]; then
        cp "$EFFECTIVE_ICON_SRC" "$APP_DIR/Contents/Resources/${ICON_NAME}.icns"
        cp "$EFFECTIVE_ICON_SRC" "$APPEX_DIR/Contents/Resources/${ICON_NAME}.icns"
        echo "  Copied icon to App and Appex from $EFFECTIVE_ICON_SRC"
    else
        echo "  Warning: No valid icon found"
    fi

    # Generate Share Extension Info.plist
    # Note: NSExtensionActivationRule MUST be inside NSExtensionAttributes
    # CFBundleName is WechatShare, CFBundleDisplayName is $TARGET_APP_NAME
    cat << EOF > "$APPEX_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>$TARGET_APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>WechatShare</string>
    <key>CFBundleIconFile</key>
    <string>$ICON_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$APPEX_BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>WechatShare</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionAttributes</key>
        <dict>
            <key>NSExtensionActivationRule</key>
            <string>$ACTIVATION_RULE</string>
        </dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.share-services</string>
        <key>NSExtensionPrincipalClass</key>
        <string>ShareViewController</string>
    </dict>
</dict>
</plist>
EOF

    # Generate Host App Info.plist
    # Note: LSUIElement = true so it runs in background without dock icon bounce
    cat << EOF > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>$TARGET_APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>$ICON_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$HOST_BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$TARGET_APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>TargetAppName</key>
    <string>$TARGET_APP_NAME</string>
    <key>TargetAppBundleID</key>
    <string>$TARGET_BUNDLE_ID</string>
    <key>TargetAppFallbackPath</key>
    <string>$TARGET_FALLBACK_PATH</string>
    <key>AutoPasteMode</key>
    <string>$AUTO_PASTE_MODE</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Zip Archive</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.zip-archive</string>
                <string>com.pkware.zip-archive</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

    # Codesign inside-out
    echo "  Signing embedded Share Extension with sandbox entitlements..."
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APPEX_DIR"

    echo "  Signing Host Application..."
    codesign --force --sign - "$APP_DIR"

    echo "  Verifying signatures..."
    codesign --verify --deep --strict "$APP_DIR"
    echo "  [SUCCESS] $APP_NAME.app successfully built and verified."
}

# 1. Build WeChatToAntigravity.app
build_app \
    "WeChatToAntigravity" \
    "io.github.bilppppp.wx2ai.antigravity" \
    "转发到 Antigravity" \
    "com.google.antigravity" \
    "/Applications/Antigravity.app" \
    "/Applications/Antigravity.app/Contents/Resources/icon.icns" \
    "icon" \
    "keystroke"

# 2. Build WeChatToCodex.app
build_app \
    "WeChatToCodex" \
    "io.github.bilppppp.wx2ai.codex" \
    "转发到 Codex" \
    "com.openai.codex" \
    "/Applications/ChatGPT.app" \
    "/Applications/ChatGPT.app/Contents/Resources/app.icns" \
    "app" \
    "keystroke"

# 3. Build WeChatToClipboard.app
build_app \
    "WeChatToClipboard" \
    "io.github.bilppppp.wx2ai.clipboard" \
    "转发到剪贴板" \
    "clipboard" \
    "" \
    "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ClippingText.icns" \
    "ClippingText" \
    "clipboard"

echo "========================================"
echo "All apps built successfully in $DIST_DIR:"
ls -lh "$DIST_DIR"
echo "========================================"
