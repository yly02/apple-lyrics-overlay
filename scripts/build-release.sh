#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION" 2>/dev/null || true)"
if [ -z "$VERSION" ]; then
    VERSION="1.0.0"
fi

DIST_DIR="$ROOT_DIR/dist"
APP_NAME="Apple Music Lyrics.app"
ZIP_NAME="Apple-Music-Lyrics-${VERSION}-macOS.zip"
CHECKSUM_NAME="${ZIP_NAME}.sha256"
APP_PATH="$DIST_DIR/$APP_NAME"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
CHECKSUM_PATH="$DIST_DIR/$CHECKSUM_NAME"

mkdir -p "$DIST_DIR"
rm -rf "$APP_PATH" "$ZIP_PATH" "$CHECKSUM_PATH"

"$ROOT_DIR/build-app.sh" "$APP_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" | awk '{print $1}' > "$CHECKSUM_PATH"

echo "Release app: $APP_PATH"
echo "Release zip: $ZIP_PATH"
echo "SHA256 file: $CHECKSUM_PATH"
