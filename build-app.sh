#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Apple Music Lyrics.app"
EXECUTABLE_NAME="AppleMusicLyrics"
OUTPUT_PATH="${1:-$HOME/Desktop/$APP_NAME}"
APP_VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION" 2>/dev/null || true)"
if [ -z "$APP_VERSION" ]; then
    APP_VERSION="1.0.0"
fi
CONTENTS_DIR="$OUTPUT_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$OUTPUT_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp ".build/release/apple-lyrics-overlay" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

if [ -d "$ROOT_DIR/Resources" ]; then
    cp -R "$ROOT_DIR/Resources/." "$RESOURCES_DIR/"
fi

cat >"$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Apple Music Lyrics</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.yaoly.applemusiclyrics</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Apple Music Lyrics</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>This app needs Apple Events access to read the current track and playback state from Music.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

touch "$CONTENTS_DIR/PkgInfo"
printf 'APPL????' >"$CONTENTS_DIR/PkgInfo"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$OUTPUT_PATH" >/dev/null 2>&1 || true
fi

echo "Built app bundle at: $OUTPUT_PATH"
