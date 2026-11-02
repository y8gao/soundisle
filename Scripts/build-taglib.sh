#!/usr/bin/env bash
# Builds TagLib 1.13.1 as a static library into Vendor/taglib.
# Idempotent: exits immediately once libtag.a is installed.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VENDOR="$ROOT/Vendor"
SRC="$VENDOR/taglib-src"
PREFIX="$VENDOR/taglib"
VERSION="v1.13.1"

if [[ -f "$PREFIX/lib/libtag.a" && -f "$PREFIX/include/taglib/taglib.h" ]]; then
    echo "TagLib 已构建: $PREFIX/lib/libtag.a"
    exit 0
fi

mkdir -p "$VENDOR"

if [[ ! -d "$SRC/.git" ]]; then
    git clone --depth 1 --branch "$VERSION" https://github.com/taglib/taglib.git "$SRC"
fi

cmake -S "$SRC" -B "$SRC/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
    -DBUILD_SHARED_LIBS=OFF \
    -DWITH_MP4=ON \
    -DWITH_APE=ON \
    -DWITH_WAV=ON \
    -DWITH_ASF=ON \
    -DBUILD_TESTING=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_BINDINGS=OFF

cmake --build "$SRC/build" --parallel "$(sysctl -n hw.ncpu)"
cmake --install "$SRC/build"

echo "TagLib 静态库已安装: $PREFIX/lib/libtag.a"
