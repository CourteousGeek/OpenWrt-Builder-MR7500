#!/bin/bash

set -e

VERSION="25.12.3"
PACKAGES="luci luci-ssl-openssl -wpad-basic-mbedtls wpad-mesh-openssl kmod-batman-adv luci-proto-batman-adv batctl-full rsync jq pigz tar iperf3 tcpdump"

usage() {
    echo "Usage: $0 [-v version] [-p packages]"
    echo "  -v  OpenWrt version (default: ${VERSION})"
    echo "  -p  Packages to include (default: '${PACKAGES}')"
    echo ""
    echo "Example:"
    echo "  $0 -v 25.12.0 -p 'luci luci-ssl-openssl kmod-batman-adv batctl-default'"
    exit 1
}

while getopts "v:p:h" opt; do
    case $opt in
        v) VERSION="$OPTARG" ;;
        p) PACKAGES="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

IMAGEBUILDER="openwrt-imagebuilder-${VERSION}-qualcommax-ipq60xx.Linux-x86_64"
IMAGEBUILDER_ARCHIVE="${IMAGEBUILDER}.tar.zst"
IMAGEBUILDER_URL="https://downloads.openwrt.org/releases/${VERSION}/targets/qualcommax/ipq60xx/${IMAGEBUILDER_ARCHIVE}"
OUTPUT_DIR="bin/${VERSION}"

echo "Building OpenWrt ${VERSION} for Linksys MR7500"
echo "Packages: ${PACKAGES}"
echo ""

# Download imagebuilder if not already present
if [ ! -f "${IMAGEBUILDER_ARCHIVE}" ]; then
    echo "Downloading imagebuilder..."
    wget "${IMAGEBUILDER_URL}"
else
    echo "Imagebuilder archive already present, skipping download"
fi

# Extract if not already extracted
if [ ! -d "${IMAGEBUILDER}" ]; then
    echo "Extracting imagebuilder..."
    tar --use-compress-program=unzstd -xf "${IMAGEBUILDER_ARCHIVE}"
else
    echo "Imagebuilder already extracted, skipping"
fi

cd "${IMAGEBUILDER}"

# Fix Ubuntu 24.04 prereq check issue
mkdir -p staging_dir/host && touch staging_dir/host/.prereq-build

echo "Building image..."
make image PROFILE=linksys_mr7500 FILES=../files/ PACKAGES="${PACKAGES}"

echo ""
echo "Moving output files..."
cd ..
mkdir -p "${OUTPUT_DIR}"
mv "${IMAGEBUILDER}/bin/targets/qualcommax/ipq60xx/"*.bin \
   "${IMAGEBUILDER}/bin/targets/qualcommax/ipq60xx/"*.manifest \
   "${IMAGEBUILDER}/bin/targets/qualcommax/ipq60xx/sha256sums" \
   "${OUTPUT_DIR}/" 2>/dev/null || true

echo "Cleaning up..."
rm -rf "${IMAGEBUILDER}"
rm -f "${IMAGEBUILDER_ARCHIVE}"

echo ""
echo "Build complete! Images are in: ${OUTPUT_DIR}/"
ls -la "${OUTPUT_DIR}/"
