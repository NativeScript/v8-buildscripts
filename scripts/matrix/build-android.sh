#!/bin/bash
set -e
#
# Builds libv8_monolith.a for one Android ABI into dist/android-<abi>/.
#
# Usage: build-android.sh --abi <abi> [--v8-dir <path>] [--ndk-root <path>]
#                         [-- <ninja args>]
#

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT_DIR/config.env"

V8_DIR="$ROOT_DIR/.v8/v8"
NDK_ROOT=""
ABI=""
NINJA_ARGS=()

usage() {
    cat <<EOF
Usage: $(basename "$0") --abi <abi> [--v8-dir <path>] [--ndk-root <path>] [-- <ninja args>]

  --abi <abi>        armeabi-v7a | arm64-v8a | x86 | x86_64
  --v8-dir <path>    V8 sources (default: $V8_DIR)
  --ndk-root <path>  NDK to build against; must be the same one the runtime is
                     built with. Defaults to \$ANDROID_NDK_ROOT.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --abi)        ABI="$2"; shift 2 ;;
        --abi=*)      ABI="${1#*=}"; shift ;;
        --v8-dir)     V8_DIR="$2"; shift 2 ;;
        --v8-dir=*)   V8_DIR="${1#*=}"; shift ;;
        --ndk-root)   NDK_ROOT="$2"; shift 2 ;;
        --ndk-root=*) NDK_ROOT="${1#*=}"; shift ;;
        --)           shift; NINJA_ARGS=("$@"); break ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[ -n "$NDK_ROOT" ] || NDK_ROOT="${ANDROID_NDK_ROOT:-}"
if [ -z "$NDK_ROOT" ] || [ ! -d "$NDK_ROOT" ]; then
    echo "--ndk-root (or \$ANDROID_NDK_ROOT) must point at an NDK." >&2
    exit 1
fi

case "$ABI" in
    armeabi-v7a) CPU="arm"   ;;
    arm64-v8a)   CPU="arm64" ;;
    x86)         CPU="x86"   ;;
    x86_64)      CPU="x64"   ;;
    *) echo "Invalid --abi '$ABI'" >&2; usage >&2; exit 1 ;;
esac

# The 32-bit targets build mksnapshot and the bytecode-builtins generator as
# 32-bit x86 host binaries, which v8config.h only permits from an ia32-capable
# host. That is why these ABIs cannot be produced on macOS.
if [ "$(uname)" != "Linux" ] && { [ "$CPU" = "arm" ] || [ "$CPU" = "x86" ]; }; then
    echo "$ABI requires a linux/amd64 host (32-bit snapshots need an ia32 host)." >&2
    exit 1
fi

# Reproduces the shape of the 10.3 build these libraries replace: JIT and
# WebAssembly on, i18n off. Every deviation from the gn defaults is deliberate:
#
#   v8_array_buffer_internal_field_count / ..._view_...
#       Defaulted to 2 in 10.3, default to 0 in 14.9. The Android runtime
#       marshals an ArrayBuffer to a Java NIO buffer by linking its
#       JSInstanceInfo into internal field 0 of the buffer object itself, so
#       0 fields breaks every such conversion. v8-array-buffer.h also still
#       falls back to 2 when the macro is undefined, so the default puts V8 and
#       the embedder out of agreement.
#   v8_enable_sandbox
#       Pinned off rather than left to follow pointer compression, which would
#       change the object layout the runtime compiles against.
#   use_allocator_shim
#       Wraps malloc through linker --wrap flags the embedder would also have
#       to pass. PartitionAlloc stays (V8 depends on the target).
#   use_thin_lto / chrome_pgo_phase
#       Both turned on by is_official_build. ThinLTO emits bitcode the NDK
#       cannot link, and standalone V8 has no PGO profile script.
#   v8_enable_temporal_support
#       Temporal is Rust and needs a sysroot this build does not link.
GN_ARGS="
    target_os=\"android\"
    is_component_build=false
    is_debug=false
    is_official_build=true
    chrome_pgo_phase=0
    treat_warnings_as_errors=false
    symbol_level=0
    use_thin_lto=false
    default_min_sdk_version=21

    use_custom_libcxx=false
    icu_use_data_file=false

    use_allocator_shim=false
    use_partition_alloc_as_malloc=false

    v8_array_buffer_internal_field_count=2
    v8_array_buffer_view_internal_field_count=2

    v8_monolithic=true
    v8_static_library=true
    v8_use_external_startup_data=false

    v8_enable_i18n_support=false
    v8_enable_webassembly=true
    v8_enable_sandbox=false
    v8_enable_temporal_support=false
    v8_enable_v8_checks=false
    v8_enable_debugging_features=false
    v8_control_flow_integrity=false
"

OUTFOLDER="out.gn/android-$CPU-release"
DIST="$ROOT_DIR/dist/android-$ABI"

cd "$V8_DIR"

# ninja never deletes outputs orphaned by a config change, so a reused output
# directory silently keeps stale objects from a previous V8 version.
rm -rf "$OUTFOLDER"
gn gen "$OUTFOLDER" --args="$GN_ARGS target_cpu=\"$CPU\" v8_target_cpu=\"$CPU\" android_ndk_root=\"$NDK_ROOT\""

echo "Building $ABI: $(date)"
ninja "${NINJA_ARGS[@]}" -C "$OUTFOLDER" v8_monolith
echo "Finished $ABI: $(date)"

mkdir -p "$DIST/lib" "$DIST/include"
cp "$OUTFOLDER/obj/libv8_monolith.a" "$DIST/lib/"

# The public headers are architecture-independent but are shipped per artifact
# so that a consumer only has to fetch one thing.
rsync -a --delete "$V8_DIR/include/" "$DIST/include/"
mkdir -p "$DIST/include/inspector"
cp "$OUTFOLDER/gen/include/inspector/"*.h "$DIST/include/inspector/"

echo "$V8_VERSION" > "$DIST/V8_VERSION"
du -h "$DIST/lib/libv8_monolith.a"
