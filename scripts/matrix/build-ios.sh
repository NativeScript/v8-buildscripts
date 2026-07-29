#!/bin/bash
set -e
#
# Builds the V8 static libraries for one Apple variant into dist/ios-<variant>/.
#
# Usage: build-ios.sh --variant <variant> [--v8-dir <path>] [-- <ninja args>]
#
# Variants: arm64-device, arm64-simulator, x64-simulator,
#           arm64-catalyst, x64-catalyst
#
# Unlike Android, V8 has no monolith target here -- the iOS runtime links a set
# of per-module archives, so each is rebuilt from its objects. ninja emits thin
# archives (references, not objects), which cannot be shipped, so copying the
# .a files it produces is not an option.
#

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT_DIR/config.env"

V8_DIR="$ROOT_DIR/.v8/v8"
VARIANT=""
NINJA_ARGS=()

usage() {
    cat <<EOF
Usage: $(basename "$0") --variant <variant> [--v8-dir <path>] [-- <ninja args>]

  --variant   arm64-device | arm64-simulator | x64-simulator
              | arm64-catalyst | x64-catalyst
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --variant)   VARIANT="$2"; shift 2 ;;
        --variant=*) VARIANT="${1#*=}"; shift ;;
        --v8-dir)    V8_DIR="$2"; shift 2 ;;
        --v8-dir=*)  V8_DIR="${1#*=}"; shift ;;
        --)          shift; NINJA_ARGS=("$@"); break ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

case "$VARIANT" in
    arm64-device)    CPU=arm64; TARGET_ENV=device    ;;
    arm64-simulator) CPU=arm64; TARGET_ENV=simulator ;;
    x64-simulator)   CPU=x64;   TARGET_ENV=simulator ;;
    arm64-catalyst)  CPU=arm64; TARGET_ENV=catalyst  ;;
    x64-catalyst)    CPU=x64;   TARGET_ENV=catalyst  ;;
    *) echo "Invalid --variant '$VARIANT'" >&2; usage >&2; exit 1 ;;
esac

[ "$(uname)" = "Darwin" ] || { echo "Apple variants require a macOS host." >&2; exit 1; }

MODULES=(
    cppgc_base
    torque_generated_definitions
    torque_generated_initializers
    v8_base_without_compiler
    v8_bigint
    v8_compiler
    v8_heap_base
    v8_heap_base_headers
    v8_libbase
    v8_libplatform
    v8_snapshot
)

# iOS proper cannot JIT, so it is built in lite mode. Catalyst runs on macOS,
# where JIT is permitted, and is deliberately not lite -- keeping the two arg
# sets distinct preserves what each currently ships.
#
# cppgc_enable_caged_heap=false is load-bearing and not implied by anything
# else here. It defaults to true on arm64 ("Enable heap reservation of size
# 4GB") independently of v8_enable_pointer_compression, and enabling it forces
# cppgc_enable_pointer_compression on, whose reservation path asks for twice
# the cage to satisfy alignment. V8::Initialize() calls cppgc::InitializeProcess
# unconditionally, so every app reserved 8 GiB of 4 GiB-aligned address space at
# startup whether or not it used cppgc. iOS budgets virtual address space per
# process by device RAM, so that reservation fails outright on smaller devices
# -- four tries, then Oilpan's fatal OOM handler, before any JS runs. It crashed
# on an iPad Air while an iPad Pro was fine.
GN_ARGS="
    target_os=\"ios\"
    treat_warnings_as_errors=false
    icu_use_data_file=false
    use_custom_libcxx=false
    is_component_build=false
    is_debug=false
    ios_enable_code_signing=false
    v8_control_flow_integrity=false
    v8_monolithic=false
    v8_static_library=true
    v8_use_external_startup_data=false
    v8_enable_sandbox=false
    v8_enable_debugging_features=false
    v8_enable_i18n_support=false
    v8_enable_temporal_support=false
    v8_enable_pointer_compression=false
    v8_enable_v8_checks=false
    v8_enable_webassembly=false
    cppgc_enable_caged_heap=false
    symbol_level=0
"

if [ "$TARGET_ENV" = "catalyst" ]; then
    # is_official_build here implies ThinLTO, which emits bitcode rather than
    # object code and cannot be vendored, hence the explicit override.
    GN_ARGS="$GN_ARGS
        is_official_build=true
        use_thin_lto=false
        ios_deployment_target=\"$CATALYST_DEPLOYMENT_TARGET\""
else
    GN_ARGS="$GN_ARGS
        v8_enable_lite_mode=true
        ios_deployment_target=\"$IOS_DEPLOYMENT_TARGET\""
fi

OUTFOLDER="out.gn/$VARIANT-release"
DIST="$ROOT_DIR/dist/ios-$VARIANT"

cd "$V8_DIR"

archive_lib() {
    local name="$1" objects="$2" o
    local existing=()
    # Filter to what actually exists. Not every target is produced by every
    # configuration -- catalyst omits some of the arm64 zlib SIMD variants, for
    # instance -- and a glob that matches nothing would otherwise be handed to
    # ar verbatim.
    # shellcheck disable=SC2086 -- deliberate glob expansion
    for o in $objects; do [ -e "$o" ] && existing+=("$o"); done
    if [ ${#existing[@]} -eq 0 ]; then
        # v8_heap_base_headers is header-only and compiles to nothing. The
        # runtime still links the archive by name, so write an empty one --
        # what ships today is an 8-byte archive for exactly this reason.
        echo "note: $name has no objects, writing an empty archive"
        # macOS ar refuses to create a memberless archive, so write the magic
        # directly -- this is byte-identical to what ships today.
        printf '!<arch>\n' > "$DIST/lib/$name.a"
        return
    fi
    ar r "$DIST/lib/$name.a" "${existing[@]}"
    strip -S -x "$DIST/lib/$name.a" 2>/dev/null || true
}

rm -rf "$OUTFOLDER"
gn gen "$OUTFOLDER" --args="$GN_ARGS target_environment=\"$TARGET_ENV\" target_cpu=\"$CPU\" v8_target_cpu=\"$CPU\""

echo "Building $VARIANT: $(date)"
ninja "${NINJA_ARGS[@]}" -C "$OUTFOLDER" "${MODULES[@]}" inspector
echo "Finished $VARIANT: $(date)"

mkdir -p "$DIST/lib" "$DIST/include"

for MODULE in "${MODULES[@]}"; do
    archive_lib "lib$MODULE" "$OUTFOLDER/obj/$MODULE/*.o"
done

ZLIB_OBJS="$OUTFOLDER/obj/third_party/zlib/zlib/*.o"
if [ "$CPU" = "arm64" ]; then
    for simd in zlib_adler32_simd zlib_arm_crc32 zlib_data_chunk_simd zlib_inflate_chunk_simd; do
        ZLIB_OBJS="$ZLIB_OBJS $OUTFOLDER/obj/third_party/zlib/$simd/*.o"
    done
fi
ZLIB_OBJS="$ZLIB_OBJS $OUTFOLDER/obj/third_party/zlib/google/compression_utils_portable/*.o"
archive_lib "libzip" "$ZLIB_OBJS"

archive_lib "libcrdtp" "$OUTFOLDER/obj/third_party/inspector_protocol/crdtp/*.o"
archive_lib "libcrdtp_platform" "$OUTFOLDER/obj/third_party/inspector_protocol/crdtp_platform/*.o"
archive_lib "libinspector" "$OUTFOLDER/obj/src/inspector/inspector/*.o"
archive_lib "libinspector_string_conversions" "$OUTFOLDER/obj/src/inspector/inspector_string_conversions/*.o"

# abseil, simdutf and highway plus the libm trig sources: referenced by v8_base
# but part of no module above. zlib and inspector_protocol are excluded because
# they ship as libzip/libcrdtp; rust is excluded because disabling Temporal
# leaves only stale objects behind.
THIRD_PARTY_OBJS=$(find "$OUTFOLDER/obj/third_party" -name "*.o" \
    ! -path "*/zlib/*" ! -path "*/inspector_protocol/*" ! -path "*/rust/*" 2>/dev/null)
archive_lib "libv8_third_party" "$THIRD_PARTY_OBJS $OUTFOLDER/obj/libm/*.o"

rsync -a --delete "$V8_DIR/include/" "$DIST/include/"
mkdir -p "$DIST/include/inspector"
cp "$OUTFOLDER/gen/include/inspector/"*.h "$DIST/include/inspector/"

echo "$V8_VERSION" > "$DIST/V8_VERSION"
du -sh "$DIST/lib"
