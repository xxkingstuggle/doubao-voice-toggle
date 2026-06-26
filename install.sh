#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_FILE="$ROOT_DIR/src/DoubaoVoiceToggle.swift"
APP_SUPPORT="$HOME/Library/Application Support/DoubaoVoiceToggle"
TARGET="$APP_SUPPORT/doubao-voice-toggle"
BUILD_DIR="$ROOT_DIR/build"
BUILD_TARGET="$BUILD_DIR/doubao-voice-toggle"

mkdir -p "$APP_SUPPORT" "$BUILD_DIR"

xcrun swiftc -O \
  -framework Carbon \
  -framework ApplicationServices \
  -framework AppKit \
  "$SOURCE_FILE" \
  -o "$BUILD_TARGET"

codesign --force --sign - "$BUILD_TARGET" >/dev/null
install -m 755 "$BUILD_TARGET" "$TARGET"

echo "installed: $TARGET"
