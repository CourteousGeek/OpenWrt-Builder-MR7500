# OpenWrt Builder for Linksys MR7500

Builds a custom OpenWrt image for the Linksys MR7500 with the AQR114C PHY firmware baked into the base squashfs. This is required for WAN to work — see [openwrt/openwrt#21835](https://github.com/openwrt/openwrt/issues/21835#issuecomment-4441365793) for the full explanation.

## Prerequisites

- Docker

## Workflow

### 1. Extract AQR114C.cld from the Linksys OEM firmware

```bash
docker run --rm \
  -v "$PWD/files:/workspace/files" \
  ghcr.io/leoarry/openwrt-builder-mr7500:latest \
  ./extract-aqr-firmware.sh
```

Downloads `FW_MR7500_1.1.12.216649_prod.img`, strips the DTB header, extracts the squashfs rootfs from the UBI image, and stages `AQR114C.cld` at `files/lib/firmware/marvell/` on your host. Skip this step if you already have the file from a previous run.

If you have a different firmware version:

```bash
docker run --rm \
  -v "$PWD/files:/workspace/files" \
  ghcr.io/leoarry/openwrt-builder-mr7500:latest \
  ./extract-aqr-firmware.sh -v 1.1.12.216649
```

### 2. Build the image

```bash
docker run --rm \
  -v "$PWD/files:/workspace/files" \
  -v "$PWD/bin:/workspace/bin" \
  ghcr.io/leoarry/openwrt-builder-mr7500:latest \
  ./build-openwrt.sh
```

Downloads the OpenWrt 25.12.3 ImageBuilder, builds a factory image for `linksys_mr7500` with the firmware baked in, and places the output in `bin/25.12.3/`. Only `files/` and `bin/` are bind-mounted — the ImageBuilder runs entirely inside the container, so this works on all platforms regardless of filesystem case-sensitivity.

Options:

```bash
docker run --rm \
  -v "$PWD/files:/workspace/files" \
  -v "$PWD/bin:/workspace/bin" \
  ghcr.io/leoarry/openwrt-builder-mr7500:latest \
  ./build-openwrt.sh -v 25.12.0 -p 'luci luci-ssl-openssl kmod-batman-adv batctl-default'
```

### 3. Flash via U-Boot/TFTP

**Do not use the web UI** — `auto_recovery` will revert to OEM after 3 reboots (see [#23245](https://github.com/openwrt/openwrt/issues/23245)). Use TFTP from U-Boot and flash **both kernel partitions**.

You'll need a 3.3 V USB-UART adapter on the internal serial header (115200 8N1) and a TFTP server (e.g. [tftpd64](https://github.com/PJO2/tftpd64/releases/)) on the same subnet as the router's default U-Boot IP.

```
# Interrupt autoboot, then in U-Boot:
setenv serverip <YOUR.TFTP.SERVER.IP>
tftp 0x44000000 openwrt-25.12.3-qualcommax-ipq60xx-linksys_mr7500-squashfs-factory.bin
flash kernel
flash alt_kernel
```

One-time: configure U-Boot to pre-load the AQR firmware from the on-NAND `ethphyfw` partition before booting Linux (defense in depth):

```
setenv boot_part 1
setenv bootcmd 'aq_load_fw; run bootusb; if test $auto_recovery = no; then bootipq; elif test $boot_part = 1; then run bootpart1; else run bootpart2; fi'
saveenv
reset
```

Notes:
- The U-Boot command is `tftp`, not `tftpboot`.
- `setenv serverip` doesn't persist unless you `saveenv`.
- Linksys's `flash <partname>` wrapper auto-uses the most recent TFTP load address.
- Flashing only one partition isn't enough — flash both `kernel` and `alt_kernel`.

A successful boot looks like:

```
[  6.04s] Aquantia AQR114C 90000.mdio-1:08: loading firmware version 'v5.6.5 ... ' from 'FS'
[ 21.14s] Aquantia AQR114C 90000.mdio-1:08: attached PHY driver
[ 33.60s] nss-dp 3a003000.dp5-syn wan: PHY Link up speed: 1000
```

If the firmware load timestamp is later than ~10 s, it loaded from the overlay — the build is wrong.
