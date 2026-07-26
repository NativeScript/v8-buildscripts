#!/bin/bash
set -e
#
# Syncs and patches the V8 checkout the build scripts work from.
#
# Usage: fetch.sh --platform <android|ios> [--v8-dir <path>]
#
# <path> is the directory that will *contain* the checkout; sources land in
# <path>/v8 and the .gclient file in <path>. Requires depot_tools on PATH.
#

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT_DIR/config.env"

PLATFORM=""
V8_PARENT="$ROOT_DIR/.v8"

usage() {
    cat <<EOF
Usage: $(basename "$0") --platform <android|ios> [--v8-dir <path>]

  --platform       Which DEPS set to sync and which patches to apply.
  --v8-dir <path>  Directory to hold the checkout (default: $V8_PARENT).
                   Sources land in <path>/v8.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --platform)   PLATFORM="$2"; shift 2 ;;
        --platform=*) PLATFORM="${1#*=}"; shift ;;
        --v8-dir)     V8_PARENT="$2"; shift 2 ;;
        --v8-dir=*)   V8_PARENT="${1#*=}"; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

case "$PLATFORM" in
    android|ios) ;;
    *) echo "--platform must be android or ios" >&2; usage >&2; exit 1 ;;
esac

checkpoint() {
    echo ""
    echo "--------------------------------------------------------------------------------"
    echo "--- $(date +'%T') --- $1"
    echo "--------------------------------------------------------------------------------"
}

mkdir -p "$V8_PARENT"
cd "$V8_PARENT"

checkpoint "Fetching V8 $V8_VERSION for $PLATFORM"
gclient config --name v8 --unmanaged "https://chromium.googlesource.com/v8/v8.git"

# gclient config does not write a target_os, and the platform-specific DEPS
# (android_toolchain, the iOS SDK bits) are only pulled when it is present.
if ! grep -q "target_os" .gclient; then
    echo "target_os = ['$PLATFORM']" >> .gclient
elif ! grep -q "'$PLATFORM'" .gclient; then
    sed -i.bak "s/target_os = \[/target_os = ['$PLATFORM', /" .gclient && rm -f .gclient.bak
fi

checkpoint "Syncing"
# No --deps here on purpose. Restricting the DEPS OS list to the target platform
# also drops the *host* entries, and the linux sysroot hook is one of them --
# which then fails gn gen with "Missing sysroot
# (//build/linux/debian_bullseye_amd64-sysroot)" for the host toolchain that
# torque and mksnapshot are built with. target_os in .gclient already selects
# the target deps, and additionally keeping the host ones is what we want.
gclient sync --reset --with_branch_head \
    --revision "$V8_VERSION" --delete_unversioned_trees

checkpoint "Patching"
# Restores WeakCallbackType::kFinalizer, removed upstream right after 10.3.22.
# Both runtimes' object managers depend on resurrecting finalizers.
git -C v8 apply "$ROOT_DIR/patches/v8_resurrecting_finalizers.patch"

if [ "$PLATFORM" = "android" ]; then
    # API 21 and a selectable android_ndk_root are needed on every host; the
    # host-assert change in the same patch is a no-op on Linux.
    git -C v8/build apply "$ROOT_DIR/patches/android_build.patch"
fi

checkpoint "Done"
