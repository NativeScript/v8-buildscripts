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
  default_min_sdk_version=17
  symbol_level=0
  v8_enable_v8_checks=false
  v8_enable_debugging_features=false
  v8_enable_webassembly=true
  v8_use_external_startup_data=false
  is_official_build=true
  target_os=\"${PLATFORM}\"
"

if [[ ${PLATFORM} = "ios" ]]; then
  GN_ARGS_BASE="${GN_ARGS_BASE} enable_ios_bitcode=false use_xcode_clang=true ios_enable_code_signing=false v8_enable_pointer_compression=false ios_deployment_target=\"${IOS_DEPLOYMENT_TARGET}\""
elif [[ ${PLATFORM} = "android" ]]; then
  # Workaround v8 sysroot build issues with custom ndk
  GN_ARGS_BASE="${GN_ARGS_BASE} use_thin_lto=false use_sysroot=false"
fi

if [[ ${NO_INTL} = "true" ]]; then
  GN_ARGS_BASE="${GN_ARGS_BASE} v8_enable_i18n_support=false"
fi

if [[ ${NO_JIT} = "true" ]]; then
  GN_ARGS_BASE="${GN_ARGS_BASE} v8_enable_lite_mode=true"
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

  date ; ninja ${NINJA_PARAMS} -C "out.v8.${arch}" ; date
  copyLib $arch
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

if [[ ${ARCH} ]]; then
  buildArch "${ARCH}"
elif [[ ${PLATFORM} = "android" ]]; then
  # buildArch "arm"
  # buildArch "x86"
  buildArch "arm64"
  # buildArch "x64"
elif [[ ${PLATFORM} = "ios" ]]; then
  buildArch "arm64"
  # buildArch "x64"
fi
