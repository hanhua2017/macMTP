#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="macMTP"
APP_BUNDLE="$PROJECT_ROOT/$APP_NAME.app"
BUILD_MODE="debug"
BUILD_UNIVERSAL=false
TARGET_ARCH="$(uname -m)"
MIN_RUNTIME_MACOS_VERSION="14.0"

usage() {
    cat <<EOF
Usage: scripts/build.sh [debug|release] [--arch arm64|x86_64] [--universal]
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        debug|release)
            BUILD_MODE="$1"
            shift
            ;;
        --arch)
            TARGET_ARCH="${2:?missing value for --arch}"
            shift 2
            ;;
        -u|--universal)
            BUILD_UNIVERSAL=true
            TARGET_ARCH="universal"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ "$TARGET_ARCH" != "arm64" && "$TARGET_ARCH" != "x86_64" && "$TARGET_ARCH" != "universal" ]]; then
    echo "ERROR: Unsupported architecture: $TARGET_ARCH"
    exit 1
fi

# Default native builds use isolated macOS 14 dependencies, never host Homebrew bottles.
if [[ "$BUILD_UNIVERSAL" != true && -z "${MACMTP_LIBMTP_ROOT:-}" && -z "${MACMTP_LIBMTP_LIB_DIR:-}" ]]; then
    export MACMTP_RUNTIME_PREFIX="${MACMTP_RUNTIME_PREFIX:-$PROJECT_ROOT/thirdparty/runtime/$TARGET_ARCH-macos14}"
    if [[ ! -f "$MACMTP_RUNTIME_PREFIX/lib/libmtp.9.dylib" ]]; then
        bash "$SCRIPT_DIR/build-runtime.sh" "$TARGET_ARCH"
    fi
fi
if [[ -n "${MACMTP_RUNTIME_PREFIX:-}" ]]; then
    export MACMTP_LIBMTP_LIB_DIR="${MACMTP_LIBMTP_LIB_DIR:-$MACMTP_RUNTIME_PREFIX/lib}"
    if [[ "$TARGET_ARCH" == arm64 ]]; then
        export MACMTP_ARM64_LIBUSB_PKGCONFIG="$MACMTP_RUNTIME_PREFIX/lib/pkgconfig"
    elif [[ "$TARGET_ARCH" == x86_64 ]]; then
        export MACMTP_X86_64_LIBUSB_PKGCONFIG="$MACMTP_RUNTIME_PREFIX/lib/pkgconfig"
    fi
fi

echo "========================================"
echo "  macMTP Build"
echo "  Mode: $BUILD_MODE"
echo "  Target: $TARGET_ARCH"
echo "========================================"

for tool in swift codesign pkg-config xcrun; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: Required tool '$tool' was not found."
        exit 1
    fi
done

triple_for() {
    case "$1" in
        arm64) echo "arm64-apple-macosx" ;;
        x86_64) echo "x86_64-apple-macosx" ;;
        *) echo "ERROR: unsupported Swift arch $1" >&2; exit 1 ;;
    esac
}

libusb_pc_dir_for() {
    local arch="$1"
    local candidates=()

    if [[ "$arch" == "arm64" ]]; then
        candidates+=(
            "${MACMTP_ARM64_LIBUSB_PKGCONFIG:-}"
            "/opt/homebrew/opt/libusb/lib/pkgconfig"
            "/opt/homebrew/lib/pkgconfig"
        )
    else
        candidates+=(
            "${MACMTP_X86_64_LIBUSB_PKGCONFIG:-}"
            "/usr/local/opt/libusb/lib/pkgconfig"
            "/usr/local/lib/pkgconfig"
        )
    fi

    for candidate in "${candidates[@]}"; do
        if [[ -n "$candidate" && -f "$candidate/libusb-1.0.pc" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    if pkg-config --exists libusb-1.0 2>/dev/null; then
        pkg-config --variable=pcfiledir libusb-1.0
        return 0
    fi

    echo "ERROR: libusb pkg-config file not found for $arch." >&2
    echo "Install libusb for that architecture or set MACMTP_${arch}_LIBUSB_PKGCONFIG." >&2
    exit 1
}

libusb_lib_dir_for() {
    local pc_dir="$1"
    PKG_CONFIG_PATH="$pc_dir" pkg-config --variable=libdir libusb-1.0
}

libusb_dylib_for() {
    local lib_dir="$1"
    for dylib in "$lib_dir/libusb-1.0.0.dylib" "$lib_dir/libusb-1.0.dylib"; do
        if [[ -f "$dylib" ]]; then
            echo "$dylib"
            return 0
        fi
    done
    echo "ERROR: libusb dylib not found in $lib_dir" >&2
    exit 1
}

validate_dylib_arch() {
    local dylib="$1"
    local arch="$2"
    if ! lipo -archs "$dylib" | tr ' ' '\n' | grep -qx "$arch"; then
        echo "ERROR: $dylib does not contain $arch. Found: $(lipo -archs "$dylib")"
        exit 1
    fi
}

LIBMTP_ROOT="${MACMTP_LIBMTP_ROOT:-$PROJECT_ROOT/thirdparty/sources/libmtp-1.1.23}"
LIBMTP_LIB_DIR="${MACMTP_LIBMTP_LIB_DIR:-$LIBMTP_ROOT/src/.libs}"

build_swift_arch() {
    local arch="$1"
    local config="$2"
    local pc_dir lib_dir triple build_dir

    pc_dir="$(libusb_pc_dir_for "$arch")"
    lib_dir="$(libusb_lib_dir_for "$pc_dir")"
    triple="$(triple_for "$arch")"

    echo "  Building Swift target for $arch using libusb from $lib_dir" >&2
    if [[ "$config" == "release" ]]; then
        MACMTP_LIBUSB_LIB_DIR="$lib_dir" \
        MACMTP_LIBMTP_ROOT="$LIBMTP_ROOT" \
        MACMTP_LIBMTP_LIB_DIR="$LIBMTP_LIB_DIR" \
        swift build -c release --triple "$triple" \
            -Xswiftc -Xfrontend -Xswiftc -disable-round-trip-debug-types >&2
        build_dir="$PROJECT_ROOT/.build/$triple/release"
    else
        MACMTP_LIBUSB_LIB_DIR="$lib_dir" \
        MACMTP_LIBMTP_ROOT="$LIBMTP_ROOT" \
        MACMTP_LIBMTP_LIB_DIR="$LIBMTP_LIB_DIR" \
        swift build --triple "$triple" >&2
        build_dir="$PROJECT_ROOT/.build/$triple/debug"
    fi

    echo "$build_dir/macmtp"
}

copy_libusb_for_bundle() {
    local arch="$1"
    local destination="$2"
    local pc_dir lib_dir dylib

    pc_dir="$(libusb_pc_dir_for "$arch")"
    lib_dir="$(libusb_lib_dir_for "$pc_dir")"
    dylib="$(libusb_dylib_for "$lib_dir")"
    validate_dylib_arch "$dylib" "$arch"
    cp "$dylib" "$destination"
}

rewrite_libusb_in_binary() {
    local bin="$1"
    local ref
    ref="$(otool -L "$bin" | grep 'libusb' | awk '{print $1}')"
    if [[ -z "$ref" ]]; then
        echo "ERROR: No libusb reference found in $bin" >&2
        exit 1
    fi
    echo "  Rewriting dylib reference in $(basename "$bin"): $ref -> @executable_path/libusb.dylib"
    install_name_tool -change "$ref" "@executable_path/libusb.dylib" "$bin"
}

dylib_reference_for() {
    local binary="$1"
    local dylib_name="$2"

    otool -L "$binary" | awk -v dylib_name="$dylib_name" '
        NR > 1 && ($1 == dylib_name || $1 ~ ("/" dylib_name "$")) {
            print $1
            exit
        }
    '
}

runtime_dylib_source() {
    local reference="$1"
    local fallback="$2"

    if [[ "$reference" = /* && -f "$reference" ]]; then
        echo "$reference"
        return 0
    fi
    if [[ -f "$fallback" ]]; then
        echo "$fallback"
        return 0
    fi

    echo "ERROR: Runtime dylib not found: $reference (fallback: $fallback)" >&2
    exit 1
}

copy_runtime_dylib() {
    local source="$1"
    local dest_name="$2"
    local destination="$APP_BUNDLE/Contents/MacOS/$dest_name"

    if [[ ! -f "$source" ]]; then
        echo "ERROR: Runtime dylib not found: $source" >&2
        exit 1
    fi
    cp "$source" "$destination"
    chmod +w "$destination"
    install_name_tool -id "@executable_path/$dest_name" "$destination"
}

rewrite_dylib_reference() {
    local binary="$1"
    local dylib_name="$2"
    local dest_name="${3:-$dylib_name}"
    local reference

    reference="$(dylib_reference_for "$binary" "$dylib_name")"
    if [[ -z "$reference" ]]; then
        echo "ERROR: No $dylib_name reference found in $binary" >&2
        exit 1
    fi
    install_name_tool -change "$reference" "@executable_path/$dest_name" "$binary"
}

verify_dylib_reference() {
    local binary="$1"
    local dylib_name="$2"
    local dest_name="${3:-$dylib_name}"
    local expected="@executable_path/$dest_name"
    local reference

    reference="$(dylib_reference_for "$binary" "$dest_name")"
    if [[ "$reference" != "$expected" ]]; then
        echo "ERROR: $binary references $reference for $dylib_name; expected $expected" >&2
        exit 1
    fi
}

validate_universal_runtime_dylibs() {
    local dylib archs

    for dylib in "$@"; do
        archs="$(lipo -archs "$dylib")"
        if ! printf '%s\n' "$archs" | tr ' ' '\n' | grep -qx arm64 || \
            ! printf '%s\n' "$archs" | tr ' ' '\n' | grep -qx x86_64; then
            echo "ERROR: Universal builds require fat runtime dylibs containing arm64 and x86_64." >&2
            echo "ERROR: $dylib contains: $archs" >&2
            echo "Provide fat dylibs or architecture-specific dependency directories." >&2
            exit 1
        fi
    done
}

macos_version_exceeds() {
    local actual="$1"
    local target="$2"

    awk -v actual="$actual" -v target="$target" '
        BEGIN {
            actual_count = split(actual, actual_parts, ".")
            target_count = split(target, target_parts, ".")
            for (part_index = 1; part_index <= 3; part_index++) {
                actual_part = part_index <= actual_count ? actual_parts[part_index] + 0 : 0
                target_part = part_index <= target_count ? target_parts[part_index] + 0 : 0
                if (actual_part > target_part) exit 0
                if (actual_part < target_part) exit 1
            }
            exit 1
        }
    '
}

validate_runtime_dylib_minos() {
    local dylib build_info minos

    for dylib in "$@"; do
        if ! build_info="$(xcrun vtool -show-build "$dylib")"; then
            echo "ERROR: Could not inspect bundled runtime dylib with vtool: $dylib" >&2
            return 1
        fi
        minos="$(printf '%s\n' "$build_info" | awk '$1 == "minos" { print $2 }')"
        if [[ -z "$minos" ]]; then
            echo "ERROR: Could not determine minimum macOS version for bundled runtime dylib: $dylib" >&2
            return 1
        fi
        while IFS= read -r minos; do
            if macos_version_exceeds "$minos" "$MIN_RUNTIME_MACOS_VERSION"; then
                echo "ERROR: $dylib requires macOS $minos, above the supported macOS $MIN_RUNTIME_MACOS_VERSION." >&2
                echo "Rebuild dependencies with MACOSX_DEPLOYMENT_TARGET=$MIN_RUNTIME_MACOS_VERSION before creating a release bundle." >&2
                return 1
            fi
        done <<< "$minos"
    done
}

LIBMTP_SOURCE="$(runtime_dylib_source "$LIBMTP_LIB_DIR/libmtp.9.dylib" "$LIBMTP_LIB_DIR/libmtp.9.dylib")"
LIBGCRYPT_REFERENCE="$(dylib_reference_for "$LIBMTP_SOURCE" "libgcrypt.20.dylib")"
LIBGPG_ERROR_REFERENCE="$(dylib_reference_for "$LIBMTP_SOURCE" "libgpg-error.0.dylib")"
LIBGCRYPT_SOURCE="$(runtime_dylib_source "$LIBGCRYPT_REFERENCE" "/opt/homebrew/opt/libgcrypt/lib/libgcrypt.20.dylib")"
LIBGPG_ERROR_SOURCE="$(runtime_dylib_source "$LIBGPG_ERROR_REFERENCE" "/opt/homebrew/opt/libgpg-error/lib/libgpg-error.0.dylib")"
LIBINTL_REFERENCE="$(dylib_reference_for "$LIBGPG_ERROR_SOURCE" "libintl.8.dylib")"
LIBINTL_SOURCE=""
if [[ -n "$LIBINTL_REFERENCE" ]]; then
    LIBINTL_SOURCE="$(runtime_dylib_source "$LIBINTL_REFERENCE" "/opt/homebrew/opt/gettext/lib/libintl.8.dylib")"
fi
RUNTIME_DYLIBS=("$LIBMTP_SOURCE" "$LIBGCRYPT_SOURCE" "$LIBGPG_ERROR_SOURCE")
[[ -z "$LIBINTL_SOURCE" ]] || RUNTIME_DYLIBS+=("$LIBINTL_SOURCE")
# Validate before replacing a previously usable application bundle, in all build modes.
validate_runtime_dylib_minos "${RUNTIME_DYLIBS[@]}"
if [[ "$BUILD_UNIVERSAL" != true ]]; then
    RUNTIME_USB="$(libusb_dylib_for "$(libusb_lib_dir_for "$(libusb_pc_dir_for "$TARGET_ARCH")")")"
    validate_runtime_dylib_minos "$RUNTIME_USB"
    for RUNTIME_DYLIB in "${RUNTIME_DYLIBS[@]}" "$RUNTIME_USB"; do
        validate_dylib_arch "$RUNTIME_DYLIB" "$TARGET_ARCH"
    done
fi

if [[ "$BUILD_UNIVERSAL" == true ]]; then
    validate_universal_runtime_dylibs "${RUNTIME_DYLIBS[@]}"
fi

echo ""
echo "Step 1: Build Swift"
if [[ "$BUILD_UNIVERSAL" == true ]]; then
    ARM_BIN="$(build_swift_arch arm64 release)"
    X86_BIN="$(build_swift_arch x86_64 release)"
    rewrite_libusb_in_binary "$ARM_BIN"
    rewrite_libusb_in_binary "$X86_BIN"
    mkdir -p "$PROJECT_ROOT/.build/universal"
    lipo -create -output "$PROJECT_ROOT/.build/universal/macmtp" "$ARM_BIN" "$X86_BIN"
    SWIFT_BIN="$PROJECT_ROOT/.build/universal/macmtp"
else
    SWIFT_BIN="$(build_swift_arch "$TARGET_ARCH" "$BUILD_MODE")"
fi

if [[ ! -f "$SWIFT_BIN" ]]; then
    echo "ERROR: Swift binary not found at $SWIFT_BIN"
    exit 1
fi

echo ""
echo "Step 2: Create app bundle"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$SWIFT_BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

if [[ -f "$PROJECT_ROOT/Resources/Info.plist" ]]; then
    cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
else
    echo "ERROR: Resources/Info.plist not found"
    exit 1
fi

if [[ -f "$PROJECT_ROOT/Resources/AppIcon.icns" ]]; then
    cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
fi

find "$PROJECT_ROOT/Resources" -maxdepth 1 -name "*.lproj" -type d -exec cp -R {} "$APP_BUNDLE/Contents/Resources/" \;

# Preserve application and third-party notices in every packaged app.
LICENSE_DIR="$APP_BUNDLE/Contents/Resources/Licenses"
mkdir -p "$LICENSE_DIR"
cp "$PROJECT_ROOT/LICENSE" "$PROJECT_ROOT/THIRD_PARTY_NOTICES.md" "$LICENSE_DIR/"
cp -R "$PROJECT_ROOT/LICENSES" "$LICENSE_DIR/LICENSES"


if [[ "$BUILD_UNIVERSAL" == true ]]; then
    TMP_LIBUSB_DIR="$(mktemp -d)"
    copy_libusb_for_bundle arm64 "$TMP_LIBUSB_DIR/libusb_arm64.dylib"
    copy_libusb_for_bundle x86_64 "$TMP_LIBUSB_DIR/libusb_x86_64.dylib"
    lipo -create -output "$APP_BUNDLE/Contents/MacOS/libusb.dylib" \
        "$TMP_LIBUSB_DIR/libusb_arm64.dylib" \
        "$TMP_LIBUSB_DIR/libusb_x86_64.dylib"
    rm -rf "$TMP_LIBUSB_DIR"
else
    copy_libusb_for_bundle "$TARGET_ARCH" "$APP_BUNDLE/Contents/MacOS/libusb.dylib"
fi

install_name_tool -id "@executable_path/libusb.dylib" "$APP_BUNDLE/Contents/MacOS/libusb.dylib"

if [[ "$BUILD_UNIVERSAL" != true ]]; then
    rewrite_libusb_in_binary "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi

APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
LIBMTP_REFERENCE="$(dylib_reference_for "$APP_BINARY" "libmtp.9.dylib")"
if [[ -z "$LIBMTP_REFERENCE" ]]; then
    echo "ERROR: No libmtp.9.dylib reference found in $APP_BINARY" >&2
    exit 1
fi

copy_runtime_dylib "$LIBMTP_SOURCE" "libmtp.9.dylib"
copy_runtime_dylib "$LIBGCRYPT_SOURCE" "libgcrypt.20.dylib"
copy_runtime_dylib "$LIBGPG_ERROR_SOURCE" "libgpg-error.0.dylib"
if [[ -n "$LIBINTL_SOURCE" ]]; then copy_runtime_dylib "$LIBINTL_SOURCE" "libintl.8.dylib"; fi

validate_runtime_dylib_minos "$APP_BUNDLE/Contents/MacOS/"*.dylib

rewrite_dylib_reference "$APP_BINARY" "libmtp.9.dylib"
rewrite_dylib_reference "$APP_BINARY" "libgcrypt.20.dylib"
rewrite_dylib_reference "$APP_BINARY" "libgpg-error.0.dylib"
rewrite_dylib_reference "$APP_BUNDLE/Contents/MacOS/libmtp.9.dylib" "libusb-1.0.0.dylib" "libusb.dylib"
rewrite_dylib_reference "$APP_BUNDLE/Contents/MacOS/libmtp.9.dylib" "libgcrypt.20.dylib"
rewrite_dylib_reference "$APP_BUNDLE/Contents/MacOS/libmtp.9.dylib" "libgpg-error.0.dylib"
rewrite_dylib_reference "$APP_BUNDLE/Contents/MacOS/libgcrypt.20.dylib" "libgpg-error.0.dylib"
if [[ -n "$LIBINTL_SOURCE" ]]; then rewrite_dylib_reference "$APP_BUNDLE/Contents/MacOS/libgpg-error.0.dylib" "libintl.8.dylib"; fi

verify_dylib_reference "$APP_BINARY" "libmtp.9.dylib"
verify_dylib_reference "$APP_BINARY" "libgcrypt.20.dylib"
verify_dylib_reference "$APP_BINARY" "libgpg-error.0.dylib"
verify_dylib_reference "$APP_BUNDLE/Contents/MacOS/libmtp.9.dylib" "libusb-1.0.0.dylib" "libusb.dylib"
verify_dylib_reference "$APP_BUNDLE/Contents/MacOS/libmtp.9.dylib" "libgcrypt.20.dylib"
verify_dylib_reference "$APP_BUNDLE/Contents/MacOS/libmtp.9.dylib" "libgpg-error.0.dylib"
verify_dylib_reference "$APP_BUNDLE/Contents/MacOS/libgcrypt.20.dylib" "libgpg-error.0.dylib"
if [[ -n "$LIBINTL_SOURCE" ]]; then verify_dylib_reference "$APP_BUNDLE/Contents/MacOS/libgpg-error.0.dylib" "libintl.8.dylib"; fi

if otool -L "$APP_BUNDLE/Contents/MacOS/libgpg-error.0.dylib" | grep -Eq '(/opt/homebrew|/usr/local).*/libintl\.8\.dylib'; then
    echo "ERROR: libgpg-error.0.dylib still references a Homebrew libintl.8.dylib:" >&2
    otool -L "$APP_BUNDLE/Contents/MacOS/libgpg-error.0.dylib" | grep 'libintl.8.dylib' >&2
    exit 1
fi

if otool -L "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep 'libusb' | grep -qv '@executable_path'; then
    echo "ERROR: libusb path was not rewritten. Binary still references:"
    otool -L "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep 'libusb' | grep -v '@executable_path'
    exit 1
fi
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo ""
echo "Step 3: Code sign"
codesign -s - --force "$APP_BUNDLE/Contents/MacOS/libusb.dylib"
codesign -s - --force "$APP_BUNDLE/Contents/MacOS/libmtp.9.dylib"
codesign -s - --force "$APP_BUNDLE/Contents/MacOS/libgcrypt.20.dylib"
codesign -s - --force "$APP_BUNDLE/Contents/MacOS/libgpg-error.0.dylib"
if [[ -n "$LIBINTL_SOURCE" ]]; then codesign -s - --force "$APP_BUNDLE/Contents/MacOS/libintl.8.dylib"; fi
codesign -s - --force --deep "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo ""
echo "Build complete: $APP_BUNDLE"
echo "Binary architectures: $(lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME")"
echo "libusb architectures: $(lipo -archs "$APP_BUNDLE/Contents/MacOS/libusb.dylib")"
