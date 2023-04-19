#!/bin/bash -e
source $(dirname $0)/env.sh

if [[ -d "${BUILD_DIR}" ]]; then
  rm -rf "${BUILD_DIR}"
fi

cd "${V8_DIR}"

gclient sync --deps=${PLATFORM} --reset --with_branch_head --revision ${V8_VERSION}

cd "${ROOT_DIR}"
scripts/patch.sh ${PLATFORM}

NO_INTL=true scripts/build.sh ${PLATFORM}
NO_INTL=true scripts/archive.sh ${PLATFORM}
