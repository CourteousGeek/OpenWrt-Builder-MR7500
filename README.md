# OpenWrt for Linksys MR7500

Custom OpenWrt images for the Linksys MR7500 with fixes the upstream stock images don't ship:

1. **AQR114C PHY firmware baked into the base squashfs**, required for WAN to work on first boot — see [openwrt/openwrt#21835](https://github.com/openwrt/openwrt/issues/21835#issuecomment-4441365793).
2. **Kernel PHY patches** that make the WAN link reliable: C45 PHY detection/driver-bind fixes plus an AQR114C USXGMII system-interface fix that resolves the 2.5G WAN packet loss (see below).
3. **NSS builds only:** a device-tree patch that pins the QCN9074 6 GHz PCIe radio to ath11k firmware memory mode 1 (upstream only sets this on the AHB 2.4/5 GHz radio), reducing runtime host-memory preallocation for the 6 GHz radio.

## Releases

Pre-built images are on the [Releases](https://github.com/leoarry/openwrt-builder-mr7500/releases) page:

| Flavour | Tag format | Source | Notes |
|---------|-----------|--------|-------|
| **Vanilla** | `v25.12.x` | Official OpenWrt ImageBuilder | Standard OpenWrt with a curated package set. Stable and well-tested. |
| **NSS** | `25.12-nss-<short-sha>` | [qosmio/openwrt-ipq](https://github.com/qosmio/openwrt-ipq) `25.12-nss` branch | NSS hardware offloading plus the AQR114C WAN and QCN9074 RAM fixes above. |

### WAN reliability — kernel PHY patches

Out of the box the MR7500 WAN (Aquantia AQR114C, USXGMII) is unreliable: the aquantia driver may not bind to the Clause-45 PHY (link issues at any speed), and even when it does, the port **drops ~10–20% of packets at 2.5G** with zero error counters.

This build applies three kernel patches in [`patches/kernel/`](patches/kernel/), copied into `target/linux/qualcommax/patches-6.12/` at build time:

| Patch | What it does |
|-------|--------------|
| `0990` | Retry Clause-45 PHY detection in `fwnode_mdio` (the AQR can be slow to answer ID reads after reset) |
| `0991` | Late C45 driver-module request in `phy_device` so the aquantia driver binds instead of generic Clause-45 |
| `0992` | **The 2.5G fix:** switch the AQR114C `config_aneg` to `aqr_config_aneg_set_prot`, which programs the system-interface protocol per speed so 2.5G USXGMII is set up correctly |

`0992` is the one that eliminates the 2.5G packet loss; `0990`/`0991` ensure the aquantia driver actually drives the PHY. They use the high `099x` range so they apply after upstream patches and don't collide with qosmio's `09xx` numbering. Verified on hardware: clean 0% loss at both 1G and 2.5G.

### QCN9074 RAM fix (NSS builds)

Upstream OpenWrt sets `qcom,ath11k-fw-memory-mode = <1>` on the AHB 2.4/5 GHz radio only. The PCIe QCN9074 6 GHz radio has no fwmode in DTS and the driver defaults to mode 0, which preallocates more host memory at runtime. The `q6_region` DT carveout (55 MB) is already provided by `ipq6018-512m.dtsi` in both upstream and qosmio — this patch does not change it.

NSS builds apply [`patches/ipq6018-mr7500-qcn9074-512m.patch`](patches/ipq6018-mr7500-qcn9074-512m.patch), which adds one line: `qcom,ath11k-fw-memory-mode = <1>` on the QCN9074 PCIe node (`wifi@0,0`).

Validated on hardware: measurably more free RAM at idle (e.g. ~114 MB → ~137 MB), 6 GHz radio still up at 160 MHz.

Background: [openwrt/openwrt#19083](https://github.com/openwrt/openwrt/pull/19083), [MR7500 DTS upstreaming](https://lists.infradead.org/pipermail/lede-commits/2025-March/024785.html).

Download `*squashfs-factory.bin` from whichever release you want and proceed to [Flash via U-Boot/TFTP](#flash-via-u-boottftp).

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

Full source build from [qosmio/openwrt-ipq](https://github.com/qosmio/openwrt-ipq) (branch `25.12-nss`) with NSS hardware offloading enabled. Applies the QCN9074 device-tree patch before compiling. Takes significantly longer than the ImageBuilder path above.

The build is driven by `config-nss.seed`, which is copied into the source tree as `.config` before the build starts. It contains the target device, NSS offloading options, package selection, and compiler flags — edit it before running to customise what gets built.

Uses the official OpenWrt buildbot image which has all required toolchain dependencies.

The `nss-builder` named volume persists the cloned source tree and build artifacts (toolchain, downloaded sources, compiled objects) at `/builder` across runs, so reruns are incremental instead of starting from scratch — the build script fetches and updates the existing checkout rather than re-cloning. A named volume (not a host bind mount) is used on purpose: it lives in Docker's Linux VM and is case-sensitive, avoiding the case-collision failures that break kernel builds on Windows/macOS host filesystems. Remove it with `docker volume rm nss-builder` to force a clean build.

**Linux/macOS:**
```bash
docker run --rm \
  -v "$PWD:/workspace" \
  -v nss-builder:/builder \
  -w /workspace \
  ghcr.io/openwrt/buildbot/buildworker-v3.8.0:v9 \
  bash build-openwrt-nss.sh
```

**Windows (PowerShell):**
```powershell
docker run --rm `
  -v "${PWD}:/workspace" `
  -v nss-builder:/builder `
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
