# OpenWrt for Linksys MR7500

Custom OpenWrt images for the Linksys MR7500 with the AQR114C PHY firmware baked into the base squashfs. This is required for WAN to work on first boot — see [openwrt/openwrt#21835](https://github.com/openwrt/openwrt/issues/21835#issuecomment-4441365793) for the full explanation.

## Releases

Pre-built images are available on the [Releases](https://github.com/leoarry/openwrt-builder-mr7500/releases) page. Two flavours are published:

| Flavour | Tag format | Source | Notes |
|---------|-----------|--------|-------|
| **Vanilla** | `v25.12.x` | Official OpenWrt ImageBuilder | Standard OpenWrt, built with a curated package set. Stable and well-tested. |
| **NSS** | `25.12-nss-<short-sha>` | [qosmio/openwrt-ipq](https://github.com/qosmio/openwrt-ipq) `25.12-nss` branch | Full source build with NSS hardware offloading enabled. Higher throughput for routed/NAT traffic at the cost of a longer, less stable build cycle. |

Download the `*squashfs-factory.bin` file from whichever release you want and proceed to [Flash via U-Boot/TFTP](#flash-via-u-boottftp).

---

## Build it yourself

Only needed if you want to customise packages, the config, or the baked-in AQR firmware version. Requires Docker.

### 1. Clone the repository

```bash
git clone https://github.com/leoarry/openwrt-builder-mr7500.git
cd openwrt-builder-mr7500
```

### 2. (Optional) Extract AQR114C.cld from a different OEM firmware version

The repo includes `AQR114C.cld` pre-staged at `files/lib/firmware/marvell/`, extracted from OEM firmware `1.1.12.216649`. Skip this step unless you need a different version.

Downloads the specified OEM firmware image, strips the DTB header, extracts the squashfs rootfs from the UBI image, and overwrites `files/lib/firmware/marvell/AQR114C.cld`.

**Linux/macOS:**
```bash
docker run --rm \
  -v "$PWD/files:/workspace/files" \
  ghcr.io/leoarry/openwrt-builder-mr7500:latest \
  ./extract-aqr-firmware.sh -v 1.1.12.216649
```

**Windows (PowerShell):**
```powershell
docker run --rm `
  -v "${PWD}/files:/workspace/files" `
  ghcr.io/leoarry/openwrt-builder-mr7500:latest `
  ./extract-aqr-firmware.sh -v 1.1.12.216649
```

### 3a. Build the vanilla image

Downloads the OpenWrt ImageBuilder, builds a factory image for `linksys_mr7500` with the AQR firmware baked in, and places the output in `bin/<version>/`. Only `files/` and `bin/` are bind-mounted — the ImageBuilder runs entirely inside the container, so this works on all platforms regardless of filesystem case-sensitivity.

**Linux/macOS:**
```bash
docker run --rm \
  -v "$PWD/files:/workspace/files" \
  -v "$PWD/bin:/workspace/bin" \
  ghcr.io/leoarry/openwrt-builder-mr7500:latest \
  ./build-openwrt.sh -v 25.12.3 -p 'luci luci-ssl-openssl kmod-batman-adv batctl-default'
```

**Windows (PowerShell):**
```powershell
docker run --rm `
  -v "${PWD}/files:/workspace/files" `
  -v "${PWD}/bin:/workspace/bin" `
  ghcr.io/leoarry/openwrt-builder-mr7500:latest `
  ./build-openwrt.sh -v 25.12.3 -p 'luci luci-ssl-openssl kmod-batman-adv batctl-default'
```

### 3b. Build the NSS image

Full source build from [qosmio/openwrt-ipq](https://github.com/qosmio/openwrt-ipq) (branch `25.12-nss`) with NSS hardware offloading enabled. Takes significantly longer than the ImageBuilder path above.

The build is driven by `config-nss.seed`, which is copied into the source tree as `.config` before the build starts. It contains the target device, NSS offloading options, package selection, and compiler flags — edit it before running to customise what gets built.

Uses the official OpenWrt buildbot image which has all required toolchain dependencies.

**Linux/macOS:**
```bash
docker run --rm \
  -v "$PWD:/workspace" \
  -w /workspace \
  ghcr.io/openwrt/buildbot/buildworker-v3.8.0:v9 \
  bash build-openwrt-nss.sh
```

**Windows (PowerShell):**
```powershell
docker run --rm `
  -v "${PWD}:/workspace" `
  -w /workspace `
  ghcr.io/openwrt/buildbot/buildworker-v3.8.0:v9 `
  bash build-openwrt-nss.sh
```

---

## Flash via U-Boot/TFTP

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
