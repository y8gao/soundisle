#!/usr/bin/env bash
# Builds TagLib 1.13.1 as a universal (x86_64 + arm64) static library into
# Vendor/taglib. Idempotent: exits immediately once both slices are installed.
#
# A universal app needs a universal static dependency; linking an arm64 Swift
# binary against a single-arch libtag.a fails with "building for macOS-arm64
# but attempting to link with file built for macOS-x86_64".
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VENDOR="$ROOT/Vendor"
SRC="$VENDOR/taglib-src"
PREFIX="$VENDOR/taglib"
VERSION="v1.13.1"
ARCHS=(x86_64 arm64)

if [[ -f "$PREFIX/lib/libtag.a" && -f "$PREFIX/include/taglib/taglib.h" ]]; then
    INSTALLED_ARCHS="$(lipo -archs "$PREFIX/lib/libtag.a" 2>/dev/null || true)"
    if [[ "$INSTALLED_ARCHS" == *x86_64* && "$INSTALLED_ARCHS" == *arm64* ]]; then
        echo "TagLib 已构建（通用）: $PREFIX/lib/libtag.a"
        exit 0
    fi
fi

mkdir -p "$VENDOR"

if [[ ! -d "$SRC/.git" ]]; then
    git clone --depth 1 --branch "$VERSION" https://github.com/taglib/taglib.git "$SRC"
fi

SLICES=()
for arch in "${ARCHS[@]}"; do
    BUILD="$SRC/build-$arch"
    SLICE_PREFIX="$VENDOR/taglib-$arch"
    rm -rf "$BUILD" "$SLICE_PREFIX"
    cmake -S "$SRC" -B "$BUILD" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$SLICE_PREFIX" \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
        -DBUILD_SHARED_LIBS=OFF \
        -DWITH_MP4=ON \
        -DWITH_APE=ON \
        -DWITH_WAV=ON \
        -DWITH_ASF=ON \
        -DBUILD_TESTING=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_BINDINGS=OFF
    cmake --build "$BUILD" --parallel "$(sysctl -n hw.ncpu)"
    cmake --install "$BUILD"
    SLICES+=("$SLICE_PREFIX/lib/libtag.a")
done

rm -rf "$PREFIX"
mkdir -p "$PREFIX/lib"
lipo -create "${SLICES[@]}" -output "$PREFIX/lib/libtag.a"
cp -R "$VENDOR/taglib-x86_64/include" "$PREFIX/include"
if [[ -d "$VENDOR/taglib-x86_64/lib/pkgconfig" ]]; then
    cp -R "$VENDOR/taglib-x86_64/lib/pkgconfig" "$PREFIX/lib/pkgconfig"
fi

echo "TagLib 静态库已安装（$(lipo -archs "$PREFIX/lib/libtag.a")）: $PREFIX/lib/libtag.a"
