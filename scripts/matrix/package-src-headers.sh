#!/bin/bash
set -e
#
# Packages the V8 *internal* headers into dist/src-headers/.
#
# Both runtimes' inspector glue compiles against src/inspector, src/base,
# src/common and the crdtp headers, none of which are public API. Keeping that
# copy on a different V8 than the libraries is an ABI mismatch, so it has to
# travel with a release -- otherwise a consumer still needs a full V8 checkout
# to produce it, which defeats the point of shipping artifacts at all.
#
# The exact set each runtime needs differs (they include different roots), so
# this ships the subtrees and lets each consumer compute its own closure rather
# than baking one in here.
#
# Usage: package-src-headers.sh [--v8-dir <path>]
#

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT_DIR/config.env"

V8_DIR="$ROOT_DIR/.v8/v8"
GEN_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --v8-dir)   V8_DIR="$2"; shift 2 ;;
        --v8-dir=*) V8_DIR="${1#*=}"; shift ;;
        --gen-dir)  GEN_DIR="$2"; shift 2 ;;
        --gen-dir=*) GEN_DIR="${1#*=}"; shift ;;
        -h|--help)  echo "Usage: $(basename "$0") [--v8-dir <path>] --gen-dir <path>"; exit 0 ;;
        *)          echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

[ -d "$V8_DIR/src" ] || { echo "No V8 sources at $V8_DIR" >&2; exit 1; }

DIST="$ROOT_DIR/dist/src-headers"
rm -rf "$DIST"
mkdir -p "$DIST"

copy_headers() {
    local subdir="$1"
    [ -d "$V8_DIR/$subdir" ] || return 0
    # -inc as well as -h: absl's int128 pulls in int128_*_intrinsic.inc, and
    # several V8 headers include .inc the same way.
    (cd "$V8_DIR" && find "$subdir" \( -name '*.h' -o -name '*.inc' \) -print0) \
        | (cd "$V8_DIR" && tar --null -cf - -T -) \
        | (cd "$DIST" && tar -xf -)
}

copy_headers src
copy_headers third_party/inspector_protocol/crdtp
copy_headers third_party/abseil-cpp/absl

# src/inspector/protocol/*.h are generated into the build directory rather than
# living in the source tree, but the closure runs straight through them
# (Forward.h -> Protocol.h -> the per-domain headers), so a consumer cannot
# resolve its includes without them.
if [ -z "$GEN_DIR" ] || [ ! -d "$GEN_DIR/src/inspector/protocol" ]; then
    echo "--gen-dir must point at a build's gen/ containing src/inspector/protocol" >&2
    exit 1
fi
mkdir -p "$DIST/src/inspector/protocol"
cp "$GEN_DIR/src/inspector/protocol/"*.h "$DIST/src/inspector/protocol/"

echo "$V8_VERSION" > "$DIST/V8_VERSION"

echo "packaged $(find "$DIST" -name '*.h' -o -name '*.inc' | wc -l | tr -d ' ') headers"
du -sh "$DIST"
