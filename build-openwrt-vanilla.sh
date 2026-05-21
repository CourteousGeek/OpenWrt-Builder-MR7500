#!/bin/bash
# Full-source build of vanilla OpenWrt for the Linksys MR7500 with a specific
# ath11k fw-memory-mode pinned on both radios.
#
# This is a heavier alternative to build-openwrt.sh (ImageBuilder). It exists
# because ImageBuilder ships a pre-compiled kernel/DTB and so cannot patch the
# device tree -- which is what changes fw-memory-mode at boot. The vanilla CI
# matrix builds three variants (modes 0/1/2) per release; this script builds
# one of them.
#
# Env vars:
#   FWMODE   - ath11k fw-memory-mode 0|1|2 (default: 1)
#   VERSION  - OpenWrt release version, e.g. 25.12.3 (required)

set -e

REPO_URL="https://github.com/openwrt/openwrt.git"
REPO_DIR="openwrt"
FWMODE="${FWMODE:-1}"
VERSION="${VERSION:-}"
LOG_FILE=$(mktemp /tmp/build-vanilla-XXXXXX.log)

case "${FWMODE}" in
    0|1|2) ;;
    *)  echo "ERROR: invalid FWMODE='${FWMODE}' (must be 0, 1, or 2)" >&2
        exit 2
        ;;
esac

if [ -z "${VERSION}" ]; then
    echo "ERROR: VERSION is required (e.g. VERSION=25.12.3)" >&2
    exit 2
fi

trap 'rc=$?; if [ $rc -ne 0 ]; then echo ""; echo "=== Build failed -- last 100 lines of output ==="; tail -n 100 "${LOG_FILE}"; fi; rm -f "${LOG_FILE}"' EXIT

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

echo "Building vanilla OpenWrt ${VERSION} for Linksys MR7500 (fwmode=${FWMODE})"
echo ""

mkdir -p /builder
cd /builder

TAG="v${VERSION}"
if [ ! -d "${REPO_DIR}" ]; then
    run "Cloning openwrt/openwrt @ ${TAG}" \
        git clone --depth 1 --branch "${TAG}" "${REPO_URL}" "${REPO_DIR}"
    cd "${REPO_DIR}"
else
    cd "${REPO_DIR}"
    run "Fetching ${TAG}"      git fetch --depth 1 origin "tag" "${TAG}"
    run "Checking out ${TAG}"  git checkout "tags/${TAG}"
fi

run "Copying workspace files"        cp -r /workspace/files ./files
run "Updating feeds"                 ./scripts/feeds update -a
run "Installing feeds"               ./scripts/feeds install -a
run "Copying .config"                cp /workspace/config-vanilla.seed ./.config
run "Patching DTS fw-memory-mode=${FWMODE}" \
    python3 /workspace/scripts/apply-fwmode.py \
        --mode "${FWMODE}" \
        --dts target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-mr7500.dts
run "Running defconfig"              make defconfig V=s
run "Downloading sources"            make download -j"$(nproc)" V=s
run "Building firmware"              make -j"$(nproc)" V=s

# Stage outputs with the fwmode embedded in each filename so all three
# matrix artifacts can sit in one bin/ directory without colliding.
DEST="/workspace/bin/${VERSION}/fwmode${FWMODE}"
run "Staging outputs to ${DEST}" bash -c '
    set -e
    mkdir -p "'"${DEST}"'"
    shopt -s nullglob
    for f in ./bin/targets/qualcommax/ipq60xx/*mr7500*; do
        base=$(basename "$f")
        if [[ "$base" == *-squashfs-* ]]; then
            newname="${base/-squashfs-/-fwmode'"${FWMODE}"'-squashfs-}"
        else
            newname="fwmode'"${FWMODE}"'-$base"
        fi
        cp "$f" "'"${DEST}"'/$newname"
    done
'

echo ""
echo "Build complete! Images for fwmode=${FWMODE} are in: ${DEST}/"
ls -la "${DEST}/"
