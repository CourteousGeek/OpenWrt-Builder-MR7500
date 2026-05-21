# OpenWrt for Linksys MR7500

Custom OpenWrt images for the Linksys MR7500 with two fixes the upstream stock images don't ship:

1. **AQR114C PHY firmware baked into the base squashfs**, required for WAN to work on first boot — see [openwrt/openwrt#21835](https://github.com/openwrt/openwrt/issues/21835#issuecomment-4441365793) for the full explanation.
2. **ath11k `qcom,ath11k-fw-memory-mode` pinned on both wifi nodes, plus a matching `q6_region` carveout size**, so the PCIe QCN9074 6 GHz radio doesn't fall back to the driver default 1 GB profile and reserve 85 MB on a 512 MB router.

## Releases

Pre-built images are available on the [Releases](https://github.com/leoarry/openwrt-builder-mr7500/releases) page. Two flavours, each in **three firmware-memory-mode variants**:

| Flavour | Tag format | Source | Notes |
|---------|-----------|--------|-------|
| **Vanilla** | `v25.12.x` | [openwrt/openwrt](https://github.com/openwrt/openwrt) at the matching release tag, built from source | Standard OpenWrt with a curated package set. Stable and well‑tested. |
| **NSS** | `25.12-nss-<short-sha>` | [qosmio/openwrt-ipq](https://github.com/qosmio/openwrt-ipq) `25.12-nss` branch | NSS hardware offloading enabled. Higher throughput for routed/NAT traffic at the cost of a longer, less stable build cycle. |

### Choosing a firmware memory mode

Each release ships **six binaries** for the MR7500 — a `*-squashfs-factory.bin` (TFTP/fresh install) and a `*-squashfs-sysupgrade.bin` (sysupgrade from a running OpenWrt) for each of three ath11k `fw-memory-mode` values:

| fwmode | Profile | Peers / vdevs per radio | When to use it |
|---|---|---|---|
| `fwmode0` | ~1 GB | 512 / 17 | Avoid. This is the ath11k driver default; on a 512 MB MR7500 it reserves the full 85 MB QCN9074 host‑firmware carveout — wasteful and not what you want. |
| **`fwmode1`** | **512 MB** | **128 / 8** | **Recommended.** Matches the MR7500's 512 MB DDR3L and shrinks `q6_region` from 85 MB to 55 MB. 128 stations × 8 vdevs is far more than residential traffic ever needs. |
| `fwmode2` | 256 MB | 128 / 8 | Experimental. Same peer/vdev limits as mode 1 but shrinks `q6_region` to 32 MB and disables coldboot calibration. The 6 GHz radio (QCN9074) may fail to come up because this configuration has not been validated upstream. Useful for RAM profiling only. |

Both wifi nodes (AHB IPQ6018 2.4/5 GHz + PCIe QCN9074 6 GHz) are pinned to the same mode in every artifact, and the `q6_region` reserved-memory block is resized to match. Upstream OpenWrt only pins the AHB node — see the MR7500 DTS added in [openwrt/openwrt a1bf306](https://lists.infradead.org/pipermail/lede-commits/2025-March/024785.html) — which is why stock images keep the 6 GHz carveout at the larger profile.

Useful background:

- [openwrt/openwrt#19083](https://github.com/openwrt/openwrt/pull/19083) — the discussion between [@georgemoussalem](https://github.com/georgemoussalem) and [@robimarko](https://github.com/robimarko) that defines what mode 0/1/2 actually mean in terms of peer/vdev counts and RAM profiles. *"FW mode 0 is usually intended for boards with 1 GB of RAM, mode 1 is for 512 MB ... mode 1 offers more peers etc than 2 if you have enough RAM."*
- [`903-ath11k-support-setting-FW-memory-mode-via-DT.patch`](https://github.com/openwrt/openwrt/blob/main/package/kernel/mac80211/patches/ath11k/903-ath11k-support-setting-FW-memory-mode-via-DT.patch) — the OpenWrt patch that wires up the `qcom,ath11k-fw-memory-mode` device‑tree property the kernel reads at probe time.
- [openwrt/openwrt#17428](https://github.com/openwrt/openwrt/pull/17428) and [#18185](https://github.com/openwrt/openwrt/pull/18185) — the upstream threads that added MR7500 support (hardware spec, calibration variant, U‑Boot env layout).
- [openwrt/openwrt#19118](https://github.com/openwrt/openwrt/pull/19118) — context on how the firmware mode affects the QMI caldb size (relevant if mode 2 misbehaves on QCN9074).

Download `*-fwmode1-squashfs-factory.bin` from whichever flavour you want — or pick a different mode if you're experimenting — and proceed to [Flash via U-Boot/TFTP](#flash-via-u-boottftp).

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

### 3a. Build the vanilla image (quick, ImageBuilder)

Downloads the OpenWrt ImageBuilder, builds a factory image for `linksys_mr7500` with the AQR firmware baked in, and places the output in `bin/<version>/`. Only `files/` and `bin/` are bind-mounted — the ImageBuilder runs entirely inside the container, so this works on all platforms regardless of filesystem case-sensitivity.

> ⚠ ImageBuilder ships a **pre-compiled kernel and DTB**, so this path *cannot* apply the fwmode DT patch — the resulting image runs the QCN9074 6 GHz radio in mode 0 (the wasteful default). If you want a fwmode‑pinned image locally, use [3c](#3c-build-with-a-pinned-firmware-memory-mode-full-source) below. CI always uses the full‑source path.

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

### 3b. Build the NSS image (full source)

Full source build from [qosmio/openwrt-ipq](https://github.com/qosmio/openwrt-ipq) (branch `25.12-nss`) with NSS hardware offloading enabled. Takes significantly longer than the ImageBuilder path above.

The build is driven by `config-nss.seed`, which is copied into the source tree as `.config` before the build starts. It contains the target device, NSS offloading options, package selection, and compiler flags — edit it before running to customise what gets built.

Set `FWMODE` to `0`, `1`, or `2` to pin the ath11k firmware memory mode (defaults to `1`). The output lands in `bin/fwmode${FWMODE}/` with the mode embedded in each filename. See [Choosing a firmware memory mode](#choosing-a-firmware-memory-mode) for the trade-offs.

Uses the official OpenWrt buildbot image which has all required toolchain dependencies.

**Linux/macOS:**
```bash
docker run --rm \
  -v "$PWD:/workspace" \
  -w /workspace \
  -e FWMODE=1 \
  ghcr.io/openwrt/buildbot/buildworker-v3.8.0:v9 \
  bash build-openwrt-nss.sh
```

**Windows (PowerShell):**
```powershell
docker run --rm `
  -v "${PWD}:/workspace" `
  -w /workspace `
  -e FWMODE=1 `
  ghcr.io/openwrt/buildbot/buildworker-v3.8.0:v9 `
  bash build-openwrt-nss.sh
```

### 3c. Build with a pinned firmware memory mode (full source, vanilla)

Full source build of upstream [openwrt/openwrt](https://github.com/openwrt/openwrt) at the requested release tag, with the ath11k DT patch applied. This is what CI uses to produce the three vanilla artifacts per release. Use this if you want the same fwmode pinning locally without NSS.

Driven by `config-vanilla.seed` (mirrors the package set that `build-openwrt.sh` passes to ImageBuilder). `VERSION` and `FWMODE` are both required environment variables.

**Linux/macOS:**
```bash
docker run --rm \
  -v "$PWD:/workspace" \
  -w /workspace \
  -e VERSION=25.12.3 \
  -e FWMODE=1 \
  ghcr.io/openwrt/buildbot/buildworker-v3.8.0:v9 \
  bash build-openwrt-vanilla.sh
```

**Windows (PowerShell):**
```powershell
docker run --rm `
  -v "${PWD}:/workspace" `
  -w /workspace `
  -e VERSION=25.12.3 `
  -e FWMODE=1 `
  ghcr.io/openwrt/buildbot/buildworker-v3.8.0:v9 `
  bash build-openwrt-vanilla.sh
```

A full source build takes ~45–75 min the first time on a typical laptop. Subsequent builds reuse `staging_dir/` inside the container's `/builder` volume if you keep it across runs.

---

## Flash via U-Boot/TFTP

**Do not use the web UI** — `auto_recovery` will revert to OEM after 3 reboots (see [#23245](https://github.com/openwrt/openwrt/issues/23245)). Use TFTP from U-Boot and flash **both kernel partitions**.

You'll need a 3.3 V USB-UART adapter on the internal serial header (115200 8N1) and a TFTP server (e.g. [tftpd64](https://github.com/PJO2/tftpd64/releases/)) on the same subnet as the router's default U-Boot IP.

```
# Interrupt autoboot, then in U-Boot:
setenv serverip <YOUR.TFTP.SERVER.IP>
tftp 0x44000000 openwrt-25.12.3-qualcommax-ipq60xx-linksys_mr7500-fwmode1-squashfs-factory.bin
flash kernel
flash alt_kernel
```

(Replace `fwmode1` with `fwmode0` or `fwmode2` only if you have a reason to — see [Choosing a firmware memory mode](#choosing-a-firmware-memory-mode).)

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
