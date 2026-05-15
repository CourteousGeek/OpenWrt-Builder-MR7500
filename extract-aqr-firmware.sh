#!/bin/bash

set -e

FIRMWARE_VERSION="1.1.12.216649"

usage() {
    echo "Usage: $0 [-v firmware_version]"
    echo "  -v  Linksys firmware version (default: ${FIRMWARE_VERSION})"
    echo ""
    echo "Example:"
    echo "  $0 -v 1.1.12.216649"
    exit 1
}

while getopts "v:h" opt; do
    case $opt in
        v) FIRMWARE_VERSION="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

FIRMWARE_FILE="FW_MR7500_${FIRMWARE_VERSION}_prod.img"
FIRMWARE_URL="https://downloads.linksys.com/support/assets/firmware/${FIRMWARE_FILE}"

echo "Extracting AQR114C.cld from Linksys firmware ${FIRMWARE_VERSION}"
echo ""

# Download firmware if not already present
if [ ! -f "${FIRMWARE_FILE}" ]; then
    echo "Downloading Linksys firmware..."
    wget "${FIRMWARE_URL}"
else
    echo "Firmware already present, skipping download"
fi

echo "Stripping DTB header..."
dd if="${FIRMWARE_FILE}" bs=1M skip=8 of=mr7500_ubi.img

echo "Extracting UBI volumes..."
ubireader_extract_images -o ubi_out mr7500_ubi.img

echo "Unsquashing rootfs..."
unsquashfs -f -d rootfs ubi_out/*/img-*_vol-squashfs.ubifs

echo "Copying AQR114C.cld..."
cp rootfs/etc/AQR114C.cld .

echo "Staging firmware for imagebuilder..."
mkdir -p files/lib/firmware/marvell
cp AQR114C.cld files/lib/firmware/marvell/

echo "Cleaning up..."
rm -rf ubi_out rootfs mr7500_ubi.img "${FIRMWARE_FILE}"

echo ""
echo "Done! AQR114C.cld extracted and staged in files/lib/firmware/marvell/"
sha256sum AQR114C.cld