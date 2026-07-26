[![Build V8 matrix](https://github.com/NativeScript/v8-buildscripts/actions/workflows/build-matrix.yml/badge.svg)](https://github.com/NativeScript/v8-buildscripts/actions/workflows/build-matrix.yml)

# V8 build scripts for NativeScript

Builds the V8 static libraries that the NativeScript runtimes link, for every
Android ABI and every Apple variant, and publishes them as GitHub release
assets.

Consumed by [NativeScript/android](https://github.com/NativeScript/android) and
[NativeScript/ns-v8ios-runtime](https://github.com/NativeScript/ns-v8ios-runtime),
which fetch a pinned release rather than carrying the binaries in git.

Everything is pinned in [`config.env`](config.env): the V8 version, the Android
NDK release, and the Apple deployment targets.

## Why the libraries are not committed

Two reasons, and the second is the one that matters.

The V8 14.9 Android monoliths are 100.7 MiB (`arm64-v8a`) and 106.1 MiB
(`x86_64`), both over **GitHub's hard 100 MiB per-file push limit**. Stripping
recovers about 2%, which is not enough, and stripping a static archive risks the
link. Release assets have a 2 GB per-file limit, so they fit without argument.

More importantly, **the full matrix cannot be produced on any single machine**:

- The 32-bit Android ABIs need an ia32-capable host. `mksnapshot` and the
  bytecode-builtins generator become 32-bit x86 host binaries, and `v8config.h`
  refuses anything else — *"Target architecture arm is only supported on arm and
  ia32 host"*. On Linux they additionally need i386 multiarch installed, or they
  link and then fail to execute.
- The Apple variants need macOS.

Artifacts assembled by hand are therefore necessarily stitched together from
several machines, and nobody can reproduce or verify them. Producing them in CI
from a pinned revision, with the gn args under review, is the point of this repo.

## Matrix

| Platform | Targets | Runner |
|---|---|---|
| Android | `arm64-v8a`, `x86_64`, `armeabi-v7a`, `x86` | `ubuntu-24.04` |
| Apple | `arm64-device`, `arm64-simulator`, `x64-simulator`, `arm64-catalyst`, `x64-catalyst` | `macos-15` |

Each target is its own job with its own checkout. That costs one `gclient sync`
per job, but the sync is about 6 minutes against 90–145 minutes of compile, so
sharing it would save almost nothing.

This replaces the previous arrangement of one branch per architecture. Nine
branches meant nine places to apply a V8 bump or a patch, and cutting a release
needs a single ref to tag.

### visionOS needs no build of its own

V8's build system has no visionOS support — `target_platform` accepts only
`iphoneos` and `tvos`, `target_environment` only `simulator`, `device` and
`catalyst` — and it does not need one. The iOS runtime's `arm64-xros` and
`arm64-xrsimulator` library directories are byte-identical copies of
`arm64-iphoneos` and `arm64-iphonesimulator`, tagged `platform 2` (iOS) in both.

That works because the platform tag on a member of a *static* archive is
advisory: only the final linked image carries an `LC_BUILD_VERSION`, taken from
the link invocation. A visionOS binary links the iOS archives directly, and only
the NativeScript framework itself is built per platform.

Consumers map `ios-arm64-device` onto `arm64-xros` and `ios-arm64-simulator`
onto `arm64-xrsimulator`.

### The internal headers ship too

Both runtimes' inspector glue compiles against `src/inspector`, `src/base`,
`src/common` and the crdtp headers — none of which are public API, and all of
which have to match the libraries or they are an ABI mismatch. A release
therefore also carries `v8-<version>-src-headers.tar.gz`, so a consumer never
needs a V8 checkout to re-vendor them.

It ships the subtrees rather than a precomputed closure, because the set each
runtime needs differs. It includes the generated `src/inspector/protocol/*.h`,
which live in the build directory rather than the source tree but sit directly
in the include path of `Forward.h`.

## Releasing

The matrix runs on every push to `main` and on pull requests touching the build
inputs, so it is verified before anything is tagged. Pushing a `v8-*` tag
additionally runs the `release` job, which collects every artifact, writes
`SHA256SUMS`, and creates the GitHub release.

```sh
git tag v8-14.9.207.39-1
git push origin v8-14.9.207.39-1
```

The build number after the V8 version lets the same V8 be re-released when only
the build configuration changes.

Consumers pin a tag and verify against `SHA256SUMS` rather than trusting
whatever the URL returns.

## Building locally

```sh
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
export PATH="$PWD/depot_tools:$PATH"

scripts/matrix/fetch.sh --platform android
scripts/matrix/build-android.sh --abi arm64-v8a --ndk-root "$ANDROID_HOME/ndk/<version>"

scripts/matrix/fetch.sh --platform ios
scripts/matrix/build-ios.sh --variant arm64-device
```

Sources land in `.v8/`, output in `dist/<platform>-<target>/`. The two platforms
need different DEPS, so use separate `--v8-dir` checkouts to keep both without
re-syncing.

To iterate on one platform in CI without rebuilding the other (~2.5 hours per
platform), dispatch the workflow with `platforms: android` or `platforms: ios`.

## Patches

| Patch | Why |
|---|---|
| `v8_resurrecting_finalizers.patch` | Restores `WeakCallbackType::kFinalizer`, removed upstream immediately after 10.3.22. Both runtimes' object managers depend on resurrecting finalizers. |
| `android_build.patch` | Lowers chromium's minimum SDK to 21 (that floor is for Java/dex tooling; this builds only the native target), makes `android_ndk_root` a gn arg, and widens the hard Linux-host assert so macOS can build the 64-bit ABIs. |

## The gn args are load-bearing

They are commented at their definition in `scripts/matrix/build-android.sh` and
`scripts/matrix/build-ios.sh`. Two worth knowing:

- `v8_array_buffer_internal_field_count=2` — defaulted to 2 in 10.3 and defaults
  to 0 in 14.9. The Android runtime links a `JSInstanceInfo` into internal field
  0 of an ArrayBuffer when marshalling it to a Java NIO buffer, so 0 fields
  breaks every such conversion. `v8-array-buffer.h` still falls back to 2 when
  the macro is undefined, so the default also puts V8 and the embedder out of
  agreement.
- `use_thin_lto=false` — `is_official_build` turns ThinLTO on, and a ThinLTO
  build emits LLVM bitcode rather than object code, which the consuming
  toolchains cannot link.

The Android NDK release in `config.env` must match the one the Android runtime
is built with: libc++ is only ABI-compatible with itself across a static link,
and V8's own bundled NDK is newer than any released one.

Working out that the shipped 10.3 Android build had i18n disabled required
fingerprinting the archive with `nm`. Keeping these in one reviewed place is
most of the reason this repo exists.

## Credits

Forked from [Kudo/v8-android-buildscripts](https://github.com/Kudo/v8-android-buildscripts)
by Kudo Chien, which the original Android build pipeline came from. See
[LICENSE](LICENSE).
