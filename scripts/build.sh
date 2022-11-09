#!/bin/bash -e
source $(dirname $0)/env.sh
BUILD_TYPE="Release"
# BUILD_TYPE="Debug"

# $1 is ${PLATFORM} which parse commonly from env.sh
ARCH=$2

GN_ARGS_BASE="
  is_component_build=false
  v8_monolithic=true
  v8_static_library=true
  use_custom_libcxx=false
  icu_use_data_file=false
  treat_warnings_as_errors=false
  default_min_sdk_version=21
"

if [[ ${PLATFORM} = "macos_android" ]]; then
  GN_ARGS_BASE="${GN_ARGS_BASE} target_os=\"android\" host_cpu=\"x64\""
else
  GN_ARGS_BASE="${GN_ARGS_BASE} target_os=\"${PLATFORM}\""
fi

if [[ ${PLATFORM} = "ios" ]]; then
  GN_ARGS_BASE="${GN_ARGS_BASE} enable_ios_bitcode=false use_xcode_clang=true ios_enable_code_signing=false v8_enable_pointer_compression=false ios_deployment_target=${IOS_DEPLOYMENT_TARGET}"
elif [[ ${PLATFORM} = "android" ]]; then
  # Workaround v8 sysroot build issues with custom ndk
  GN_ARGS_BASE="${GN_ARGS_BASE} use_sysroot=false"
fi

if [[ ${NO_INTL} = "true" ]]; then
  GN_ARGS_BASE="${GN_ARGS_BASE} v8_enable_i18n_support=false"
fi

if [[ ${NO_JIT} = "true" ]]; then
  GN_ARGS_BASE="${GN_ARGS_BASE} v8_enable_lite_mode=true"
fi

if [[ ${EXTERNAL_STARTUP_DATA} = "true" || ${TOOLS_ONLY} = "true" ]]; then
  GN_ARGS_BASE="${GN_ARGS_BASE} v8_use_external_startup_data=true"
else
  GN_ARGS_BASE="${GN_ARGS_BASE} v8_use_external_startup_data=false"
fi

if [[ "$BUILD_TYPE" = "Debug" ]]
then
  GN_ARGS_BUILD_TYPE='
    is_debug=true
    symbol_level=2
  '
else
  GN_ARGS_BUILD_TYPE='
    is_debug=false
  '
fi

NINJA_PARAMS=""

if [[ ${CIRCLECI} ]]; then
  NINJA_PARAMS="-j4"
fi

cd ${V8_DIR}

function normalize_arch_for_platform()
{
  local arch=$1

  if [[ ${PLATFORM} = "ios" ]]; then
    echo ${arch}
    return
  fi

  case "$1" in
    arm)
      echo "armeabi-v7a"
      ;;
    x86)
      echo "x86"
      ;;
    arm64)
      echo "arm64-v8a"
      ;;
    x64)
      echo "x86_64"
      ;;
    *)
      echo "Invalid arch - ${arch}" >&2
      exit 1
      ;;
  esac
}

function buildArch()
{
  local arch=$1
  local platform_arch=$(normalize_arch_for_platform $arch)

  echo "Build v8 ${arch} variant NO_INTL=${NO_INTL} NO_JIT=${NO_JIT}"
  gn gen --args="${GN_ARGS_BASE} ${GN_ARGS_BUILD_TYPE} v8_target_cpu=\"${arch}\" target_cpu=\"${arch}\"" "out.v8.${arch}"

  if [[ ${TOOLS_ONLY} = "true" ]]; then
    date ; ninja ${NINJA_PARAMS} -C "out.v8.${arch}" run_mksnapshot_default mkcodecache_group ; date
    copySnapshot $arch
    copyMkcodecache $arch
 else
    date ; ninja ${NINJA_PARAMS} -C "out.v8.${arch}" v8_base_without_compiler v8_compiler v8_libplatform v8_libbase v8_bigint v8_snapshot torque_generated_initializers torque_generated_definitions cppgc_base v8_heap_base_headers v8_heap_base ; date
    copyLib $arch
    # copySnapshot $arch
    # copyMkcodecache $arch
  fi
}

function copyLib()
{
  local arch=$1
  local platform_arch=$(normalize_arch_for_platform $arch)

  mkdir -p "${BUILD_DIR}/lib/${platform_arch}"
  cp -rf "out.v8.${arch}" "${BUILD_DIR}/lib/${platform_arch}/"

  if [[ -d "out.v8.${arch}/lib.unstripped" ]]; then
    mkdir -p "${BUILD_DIR}/lib.unstripped/${platform_arch}"
    cp -rf "out.v8.${arch}/lib.unstripped" "${BUILD_DIR}/lib.unstripped/${platform_arch}/"
  fi
}

function copySnapshot()
{
  local arch=$1
  local platform_arch=$(normalize_arch_for_platform $arch)

  mkdir -p "${BUILD_DIR}/tools/${PLATFORM}/${platform_arch}"
  cp -f out.v8.${arch}/clang_*/mksnapshot "${BUILD_DIR}/tools/${PLATFORM}/${platform_arch}/mksnapshot"

  if [[ ${EXTERNAL_STARTUP_DATA} = "true" || ${TOOLS_ONLY} = "true" ]]; then
    mkdir -p "${BUILD_DIR}/snapshot_blob/${platform_arch}"
    cp -f out.v8.${arch}/snapshot_blob.bin "${BUILD_DIR}/snapshot_blob/${platform_arch}/snapshot_blob.bin"
  fi
}

function copyMkcodecache()
{
  local arch=$1
  local platform_arch=$(normalize_arch_for_platform $arch)

  mkdir -p "${BUILD_DIR}/tools/${PLATFORM}/${platform_arch}"
  cp -f out.v8.${arch}/clang_*/mkcodecache "${BUILD_DIR}/tools/${PLATFORM}/${platform_arch}/mkcodecache"

  if [[ ${EXTERNAL_STARTUP_DATA} = "true" || ${TOOLS_ONLY} = "true" ]]; then
    cp -f out.v8.${arch}/clang_*/snapshot_blob.bin "${BUILD_DIR}/tools/${PLATFORM}/${platform_arch}/snapshot_blob.bin"
  fi
}

if [[ ${ARCH} ]]; then
  buildArch "${ARCH}"
elif [[ ${PLATFORM} = "android" ]]; then
  buildArch "arm"
  buildArch "x86"
  buildArch "arm64"
  buildArch "x64"
elif [[ ${PLATFORM} = "ios" ]]; then
  buildArch "arm64"
  # buildArch "x64"
elif [[ ${PLATFORM} = "macos_android" ]]; then
  # buildArch "arm"
  # buildArch "x86"
  buildArch "arm64"
  buildArch "x64"
fi
