#!/usr/bin/env bash
# Builds build/声屿.app. Pass --universal to produce a binary that runs on both
# Intel and Apple Silicon Macs.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="声屿"
EXECUTABLE="SoundIsle"
APP_BUNDLE="build/$APP_NAME.app"
UNIVERSAL=0

case "${1:-}" in
    --universal) UNIVERSAL=1 ;;
    "") ;;
    *)
        echo "用法: $0 [--universal]" >&2
        exit 2
        ;;
esac

if [[ "$UNIVERSAL" -eq 1 ]]; then
    TAGLIB_ARCHS="$(lipo -archs Vendor/taglib/lib/libtag.a 2>/dev/null || true)"
    if [[ "$TAGLIB_ARCHS" != *x86_64* || "$TAGLIB_ARCHS" != *arm64* ]]; then
        echo "错误：通用构建需要通用版 TagLib，请先运行 bash Scripts/build-taglib.sh" >&2
        exit 1
    fi
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

if [[ "$UNIVERSAL" -eq 1 ]]; then
    swift build -c release --arch x86_64 --scratch-path .build/x86_64
    swift build -c release --arch arm64 --scratch-path .build/arm64
    X86_BIN="$(swift build -c release --arch x86_64 --scratch-path .build/x86_64 --show-bin-path)/$EXECUTABLE"
    ARM_BIN="$(swift build -c release --arch arm64 --scratch-path .build/arm64 --show-bin-path)/$EXECUTABLE"
    lipo -create "$X86_BIN" "$ARM_BIN" -output "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"
    ARCHS="$(lipo -archs "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE")"
    echo "架构: $ARCHS"
    if [[ "$ARCHS" != *x86_64* || "$ARCHS" != *arm64* ]]; then
        echo "错误：通用二进制缺少架构（$ARCHS）" >&2
        exit 1
    fi
else
    swift build -c release
    BIN_PATH="$(swift build -c release --show-bin-path)"
    cp "$BIN_PATH/$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"
fi

cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "Resources/NoteGlyph.png" "$APP_BUNDLE/Contents/Resources/NoteGlyph.png"
codesign --force --sign - "$APP_BUNDLE"

echo "已生成 $APP_BUNDLE"
