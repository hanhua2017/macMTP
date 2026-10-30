#!/usr/bin/env bash
# Build isolated runtime dependencies against the application's minimum macOS.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_ARCH="${1:-$(uname -m)}"
case "$RUNTIME_ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $RUNTIME_ARCH" >&2; exit 1 ;; esac
RUNTIME_MINOS=14.0
RUNTIME_PREFIX="${MACMTP_RUNTIME_PREFIX:-$PROJECT_ROOT/thirdparty/runtime/$RUNTIME_ARCH-macos14}"
SOURCE_CACHE="$PROJECT_ROOT/thirdparty/downloads"
BUILD_ROOT="$PROJECT_ROOT/thirdparty/build/$RUNTIME_ARCH"
bash "$PROJECT_ROOT/scripts/download.sh"
mkdir -p "$BUILD_ROOT" "$RUNTIME_PREFIX"
export MACOSX_DEPLOYMENT_TARGET="$RUNTIME_MINOS"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CC="$(xcrun -f clang)"
export CFLAGS="-O2 -arch $RUNTIME_ARCH -mmacosx-version-min=$RUNTIME_MINOS"
export CPPFLAGS="-I$RUNTIME_PREFIX/include"
export LDFLAGS="-arch $RUNTIME_ARCH -mmacosx-version-min=$RUNTIME_MINOS -L$RUNTIME_PREFIX/lib"
export PKG_CONFIG_PATH="$RUNTIME_PREFIX/lib/pkgconfig"
# Keep configure from resolving Homebrew libraries built for the host OS.
export PKG_CONFIG_LIBDIR="$RUNTIME_PREFIX/lib/pkgconfig"
export PATH="$RUNTIME_PREFIX/bin:$PATH"
RUNTIME_HOST="$RUNTIME_ARCH-apple-darwin"
[[ "$RUNTIME_ARCH" != arm64 ]] || RUNTIME_HOST=aarch64-apple-darwin
build_library() {
    local name="$1" archive="$2"
    shift 2
    if [[ ! -d "$BUILD_ROOT/$name" ]]; then tar -xf "$SOURCE_CACHE/$archive" -C "$BUILD_ROOT"; fi
    (
        cd "$BUILD_ROOT/$name"
        ./configure --host="$RUNTIME_HOST" --prefix="$RUNTIME_PREFIX" --disable-static --enable-shared "$@"
        make -j "${MACMTP_BUILD_JOBS:-4}"
        make install
    )
}
build_library libusb-1.0.29 libusb-1.0.29.tar.bz2
# Diagnostic message translation is unused by macMTP; this removes the gettext runtime dependency.
build_library libgpg-error-1.58 libgpg-error-1.58.tar.bz2 --disable-nls --disable-doc
build_library libgcrypt-1.11.2 libgcrypt-1.11.2.tar.bz2 --disable-doc --with-libgpg-error-prefix="$RUNTIME_PREFIX"
build_library libmtp-1.1.23 libmtp-1.1.23.tar.gz --disable-doxygen
for name in libusb-1.0.0.dylib libgpg-error.0.dylib libgcrypt.20.dylib libmtp.9.dylib; do
    xcrun vtool -show-build "$RUNTIME_PREFIX/lib/$name"
done
printf '%s\n' "$RUNTIME_PREFIX" > "$BUILD_ROOT/prefix.txt"
echo "Runtime dependencies: $RUNTIME_PREFIX (macOS $RUNTIME_MINOS)"
