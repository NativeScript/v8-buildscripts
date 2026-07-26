# V8 matrix build for the NativeScript runtimes

Builds the V8 static libraries that `NativeScript/android` and
`NativeScript/ns-v8ios-runtime` link, for every ABI and Apple variant, from a
single branch. Everything is pinned in [`config.env`](../../config.env).

This replaces the previous arrangement of one branch per architecture. Nine
branches meant nine places to apply a V8 bump or a patch, and a release needs a
single ref to tag.

## Matrix

| Platform | Targets | Runner |
|---|---|---|
| Android | `arm64-v8a`, `x86_64`, `armeabi-v7a`, `x86` | `ubuntu-24.04` |
| Apple | `arm64-device`, `arm64-simulator`, `x64-simulator`, `arm64-catalyst`, `x64-catalyst` | `macos-15` |

Each target is a separate job with its own checkout. That costs one `gclient
sync` per job, which the older workflow avoided by building sequentially — but
sync bandwidth is free on hosted runners and the parallel form gives far better
feedback latency. If it ever needs revisiting, the fix is a shared sync step,
not a return to one branch per arch.

### Host constraints, which are real

- **The 32-bit Android ABIs cannot be built on macOS.** `mksnapshot` and the
  bytecode-builtins generator become 32-bit x86 host binaries, and `v8config.h`
  refuses anything but an ia32-capable host: *"Target architecture arm is only
  supported on arm and ia32 host"*. On Linux they also need i386 multiarch
  installed, or they link and then fail to execute.
- **Apple variants require macOS.**
- Consequently the full set cannot be produced on any single machine, which is
  the main reason it belongs in CI rather than being assembled by hand.

### visionOS is not covered

`NativeScript/lib` contains `arm64-xros` and `arm64-xrsimulator`, but V8's build
system has no visionOS support: `target_platform` accepts only `iphoneos` and
`tvos`, and `target_environment` only `simulator`, `device` and `catalyst`.
The iOS runtime's `build_v8_source.sh` lists `arm64-xrsimulator` in its arch
array but produces no output directory for it. However those libraries are
produced today, it is not through `target_environment`, so they are out of scope
here until that is established.

## Releasing

The matrix runs on push and on pull requests touching the build inputs, so it is
verified before anything is tagged. Pushing a `v8-*` tag additionally runs the
`release` job, which collects every artifact, writes `SHA256SUMS`, and creates
the GitHub release.

```
git tag v8-14.9.207.39-1
git push origin v8-14.9.207.39-1
```

The tag carries a build number after the V8 version so the same V8 can be
re-released when only the build config changes.

Consumers pin a tag and verify the archive against `SHA256SUMS` rather than
trusting whatever the URL returns. Release assets have a 2 GB per-file limit, so
the archives fit comfortably — unlike git, where two of the Android monoliths
exceed GitHub's hard 100 MiB per-file push limit.

## Building locally

```
export PATH="$PWD/../depot_tools:$PATH"
scripts/matrix/fetch.sh --platform android
scripts/matrix/build-android.sh --abi arm64-v8a --ndk-root "$ANDROID_HOME/ndk/<version>"

scripts/matrix/fetch.sh --platform ios
scripts/matrix/build-ios.sh --variant arm64-device
```

Sources land in `.v8/`, output in `dist/<platform>-<target>/`. The two platforms
need different `--deps` sets, so use separate `--v8-dir` checkouts if you want
both without re-syncing.

## Why each non-default gn arg exists

The gn args are load-bearing and are commented at their definition in
`build-android.sh` and `build-ios.sh`. Two worth knowing about:

- `v8_array_buffer_internal_field_count=2` — defaulted to 2 in 10.3 and defaults
  to 0 in 14.9. The Android runtime links a `JSInstanceInfo` into internal field
  0 of an ArrayBuffer when marshalling it to a Java NIO buffer, so 0 fields
  breaks every such conversion. `v8-array-buffer.h` still falls back to 2 when
  the macro is undefined, so the default also puts V8 and the embedder out of
  agreement.
- `use_thin_lto=false` — `is_official_build` turns ThinLTO on, and a ThinLTO
  build emits LLVM bitcode rather than object code, which cannot be linked by
  the consuming toolchains.

Working out that the shipped 10.3 Android build had i18n disabled required
fingerprinting the archive with `nm`. Keeping these in one reviewed file is most
of the point of this branch.
