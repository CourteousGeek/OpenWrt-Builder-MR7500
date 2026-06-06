#!/bin/bash

set -e

REPO_URL="https://github.com/qosmio/openwrt-ipq.git"
REPO_BRANCH="25.12-nss"
REPO_DIR="openwrt-ipq"
LOG_FILE=$(mktemp /tmp/build-nss-XXXXXX.log)

trap 'rc=$?; if [ $rc -ne 0 ]; then echo ""; echo "=== Build failed — failing targets ==="; grep -E "\*\*\*.*Error" "${LOG_FILE}" | tail -n 20; echo ""; echo "=== Build failed — last 150 lines ==="; tail -n 150 "${LOG_FILE}"; fi; rm -f "${LOG_FILE}"' EXIT

run() {
    local desc="$1"; shift
    echo -n "${desc}... "
    if "$@" >>"${LOG_FILE}" 2>&1; then
        echo "done"
    else
        echo "failed"
        exit 1
    fi
}

echo "Building OpenWrt NSS for Linksys MR7500"
[ -n "${BUILD_SHA}" ] && echo "Target SHA: ${BUILD_SHA}" || echo "Target: HEAD of ${REPO_BRANCH}"
echo ""

mkdir -p /builder
cd /builder

if [ ! -d "${REPO_DIR}" ]; then
    if [ -n "${BUILD_SHA}" ]; then
        run "Cloning repository (full history for SHA checkout)" \
            git clone --branch "${REPO_BRANCH}" "${REPO_URL}" "${REPO_DIR}"
    else
        run "Cloning repository" \
            git clone --branch "${REPO_BRANCH}" --depth 1 "${REPO_URL}" "${REPO_DIR}"
    fi
    cd "${REPO_DIR}"
else
    run "Fetching latest" git -C "${REPO_DIR}" fetch origin "${REPO_BRANCH}"
    cd "${REPO_DIR}"
    [ -z "${BUILD_SHA}" ] && run "Updating to latest" git checkout FETCH_HEAD
fi

[ -n "${BUILD_SHA}" ] && run "Checking out ${BUILD_SHA}" git checkout "${BUILD_SHA}"

run "Copying workspace files"        cp -r /workspace/files ./files
run "Updating feeds"                 ./scripts/feeds update
run "Installing feeds"               ./scripts/feeds install -a
run "Copying .config"                cp /workspace/config-nss.seed ./.config
run "Patching MR7500 QCN9074 DTS"    patch -p1 < /workspace/patches/ipq6018-mr7500-qcn9074-512m.patch
run "Running defconfig"              make defconfig V=s
run "Downloading sources"            make download -j$(nproc) V=s
run "Building firmware"              make -j$(nproc) V=s
run "Copying output to /workspace/bin" \
    bash -c 'mkdir -p /workspace/bin && cp -r ./bin/targets/qualcommax/ipq60xx/*mr7500* /workspace/bin'

echo ""
echo "Build complete! Images are in: /workspace/bin/"
ls -la /workspace/bin/
