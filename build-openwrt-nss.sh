#!/bin/bash

set -e

REPO_URL="https://github.com/qosmio/openwrt-ipq.git"
REPO_BRANCH="25.12-nss"
REPO_DIR="openwrt-ipq"

echo "Building OpenWrt NSS for Linksys MR7500"
echo ""

mkdir -p /builder
cd /builder

if [ ! -d "${REPO_DIR}" ]; then
    echo "Cloning ${REPO_URL} (branch: ${REPO_BRANCH})..."
    git clone --branch "${REPO_BRANCH}" --depth 1 "${REPO_URL}" "${REPO_DIR}"
else
    echo "Repo already cloned, skipping"
fi

cd "${REPO_DIR}"

echo "Copying files from workspace..."
cp -r /workspace/files ./files

echo "Copying config-nss.seed as .config..."
cp /workspace/config-nss.seed ./.config

echo "Updating feeds..."
./scripts/feeds update

echo "Installing feeds..."
./scripts/feeds install -a

echo "Running defconfig..."
make defconfig V=s

echo "Downloading sources..."
make download -j$(nproc) V=s

echo "Building firmware..."
make -j$(nproc) V=s

echo ""
echo "Copying output files to /workspace/bin..."
mkdir -p /workspace/bin
cp -r ./bin/targets/qualcommax/ipq60xx/*mr7500* /workspace/bin

echo ""
echo "Build complete! Images are in: /workspace/bin/"
ls -la /workspace/bin/
