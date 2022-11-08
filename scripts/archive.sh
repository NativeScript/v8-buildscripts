#!/bin/bash -e
source $(dirname $0)/env.sh

function makeDistPackageDir() {
  if [[ ${TOOLS_ONLY} = "true" ]]; then
    echo "${DIST_DIR}/packages/v8-android-tools"
    return 0
  fi

  local jit_suffix=""
  local intl_suffix=""
  if [[ ${NO_JIT} != "true" ]]; then
    jit_suffix="-jit"
  fi

  if [[ ${NO_INTL} = "true" ]]; then
    intl_suffix="-nointl"
  fi

  echo "${DIST_DIR}/packages/v8-${PLATFORM}${jit_suffix}${intl_suffix}"
}

DIST_PACKAGE_DIR=$(makeDistPackageDir)

function createAAR() {
  printf "\n\n\t\t===================== create aar =====================\n\n"
  pushd .
  cd "${ROOT_DIR}/lib"
  ./gradlew clean :v8-android:createAAR --project-prop distDir="$DIST_PACKAGE_DIR" --project-prop version="$VERSION"
  popd
}

function copyAndroidTools() {
  printf "\n\n\t\t===================== copy android tools =====================\n\n"
  mkdir "${DIST_PACKAGE_DIR}/android"
  mkdir "${DIST_PACKAGE_DIR}/android/ndk"
  mkdir "${DIST_PACKAGE_DIR}/android/sdk"
  cp -Rf "${V8_DIR}/third_party/android_ndk" "${DIST_PACKAGE_DIR}/android/ndk"
  cp -Rf "${V8_DIR}/third_party/android_sdk" "${DIST_PACKAGE_DIR}/android/sdk"
}

function copyDylib() {
  printf "\n\n\t\t===================== copy dylib =====================\n\n"
  mkdir -p "${DIST_PACKAGE_DIR}"
  cp -Rf "${BUILD_DIR}/lib" "${DIST_PACKAGE_DIR}/"
}

function createUnstrippedLibs() {
  printf "\n\n\t\t===================== create unstripped libs =====================\n\n"
  DIST_LIB_UNSTRIPPED_DIR="${DIST_PACKAGE_DIR}/lib.unstripped/v8-${PLATFORM}/${VERSION}"
  mkdir -p "${DIST_LIB_UNSTRIPPED_DIR}"
  tar cfJ "${DIST_LIB_UNSTRIPPED_DIR}/libs.tar.xz" -C "${BUILD_DIR}/lib.unstripped" .
  unset DIST_LIB_UNSTRIPPED_DIR
}

function copyHeaders() {
  printf "\n\n\t\t===================== adding headers to ${DIST_PACKAGE_DIR}/include =====================\n\n"
  cp -Rf "${V8_DIR}/include" "${DIST_PACKAGE_DIR}/include"
}

function copyTools() {
  printf "\n\n\t\t===================== adding tools to ${DIST_PACKAGE_DIR}/tools =====================\n\n"
  cp -Rf "${BUILD_DIR}/tools" "${DIST_PACKAGE_DIR}/"
}

function copySnapshotBlobIfNeeded() {
  if [[ ${EXTERNAL_STARTUP_DATA} = "true" || ${TOOLS_ONLY} = "true" ]]; then
    printf "\n\n\t\t===================== adding snapshot_blob to ${DIST_PACKAGE_DIR}/snapshot_blob =====================\n\n"
    cp -Rf "${BUILD_DIR}/snapshot_blob" "${DIST_PACKAGE_DIR}/"
  fi
}


if [[ ${TOOLS_ONLY} = "true" ]]; then
  mkdir -p "$DIST_PACKAGE_DIR"
  copyTools
  exit 0
fi

if [[ ${PLATFORM} = "android" ]]; then
  export ANDROID_HOME="${V8_DIR}/third_party/android_sdk/public"
  export ANDROID_NDK="${V8_DIR}/third_party/android_ndk"
  export PATH=${ANDROID_HOME}/emulator:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}
  yes | sdkmanager --licenses

  mkdir -p "${DIST_PACKAGE_DIR}"
  copyDylib
  copyAndroidTools
  copyHeaders
  copyTools
  copySnapshotBlobIfNeeded
elif [[ ${PLATFORM} = "ios" ]]; then
  copyDylib
  copyHeaders
  copyTools
  copySnapshotBlobIfNeeded
fi
