#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="声屿"
EXECUTABLE="SoundIsle"
APP_BUNDLE="build/$APP_NAME.app"

swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH/$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
codesign --force --sign - "$APP_BUNDLE"

echo "已生成 $APP_BUNDLE"
