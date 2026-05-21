#!/usr/bin/env python3
"""Patch ipq6018-mr7500.dts for ath11k fw-memory-mode artifacts.

The MR7500 has three ath11k radios spread across two DTS nodes:

  - 2.4/5 GHz: on the IPQ6018 internal Q6/WCSS over AHB, node `&wifi`
  - 6 GHz:     QCN9074 over PCIe,                       node `&pcie0/pcie@0/wifi@0,0`

Upstream openwrt sets fw-memory-mode = <1> on the AHB `&wifi` node only, leaving
the PCIe `wifi@0,0` to fall through to the ath11k driver's default (mode 0 / ~1 GB
profile). On a 512 MB MR7500 that pins ~85 MB of host-firmware carveout to the
6 GHz radio. This script overrides both wifi nodes and the q6_region carveout so
each CI artifact has a coherent memory profile.

Modes (per ath11k upstream conventions):
  0 = ~1 GB profile  (512 peers, 17 vdevs per radio)
  1 = 512 MB profile (128 peers, 8 vdevs, 55 MB q6_region) -- recommended
  2 = 256 MB profile (128 peers, 8 vdevs, 32 MB q6_region, experimental)
"""

import argparse
import pathlib
import re
import sys


# Upstream MR7500 DTS (openwrt v25.12.x, qosmio 25.12-nss) uses wifi@0,0 under
# pcie@0. Older draft DTSes used wifi@1,0 under bridge@0,0 -- accept either.
PCIE_WIFI_BLOCK_RE = re.compile(
    r'wifi@\d+,\d+\s*\{([^}]*)\}',
    re.DOTALL,
)
AHB_BLOCK_RE = re.compile(r'&wifi\s*\{([^}]*)\}', re.DOTALL)
MODE_RE = re.compile(r'qcom,ath11k-fw-memory-mode\s*=\s*<\s*(\d+)\s*>\s*;')
Q6_REGION_RE = re.compile(r'&q6_region\s*\{([^}]*)\}', re.DOTALL)
Q6_REGION_SIZES = {
    0: '0x5500000',  # 85 MB: upstream/base default profile
    1: '0x3700000',  # 55 MB: OpenWrt IPQ6018 512 MB profile
    2: '0x2000000',  # 32 MB: experimental low-memory profile
}
CAL_VARIANT_RE = re.compile(
    r'(qcom,ath11k-calibration-variant\s*=\s*"Linksys-MR7500"\s*;)',
)


def _find_pcie_wifi_block(text: str):
    """Return the wifi@N,M block inside &pcie0, not any other wifi node."""
    pcie_start = text.find('&pcie0')
    if pcie_start == -1:
        return None
    # Scan only within the &pcie0 overlay (ends at the next top-level &foo).
    pcie_end = len(text)
    next_overlay = re.search(r'\n&\w', text[pcie_start + 1:])
    if next_overlay:
        pcie_end = pcie_start + 1 + next_overlay.start()
    pcie_section = text[pcie_start:pcie_end]
    return PCIE_WIFI_BLOCK_RE.search(pcie_section)


def patch_dts(dts_path: pathlib.Path, mode: int) -> None:
    text = dts_path.read_text()
    q6_size = Q6_REGION_SIZES[mode]

    # Override any existing fw-memory-mode property (upstream sets it on &wifi).
    text = MODE_RE.sub(f'qcom,ath11k-fw-memory-mode = <{mode}>;', text)

    pcie_match = _find_pcie_wifi_block(text)
    if not pcie_match:
        sys.exit(f"ERROR: could not find PCIe wifi@N,M block in {dts_path}")

    # Re-locate the match in the full text (offset by &pcie0 start).
    pcie_start = text.find('&pcie0')
    abs_start = pcie_start + pcie_match.start()
    abs_end = pcie_start + pcie_match.end()
    block_body = pcie_match.group(1)

    if 'qcom,ath11k-fw-memory-mode' not in block_body:
        injected = CAL_VARIANT_RE.sub(
            rf'\1\n\t\t\tqcom,ath11k-fw-memory-mode = <{mode}>;',
            pcie_match.group(0),
            count=1,
        )
        if injected == pcie_match.group(0):
            sys.exit("ERROR: could not insert fw-memory-mode into PCIe wifi node "
                     "(calibration-variant anchor not found)")
        text = text[:abs_start] + injected + text[abs_end:]

    # The firmware mode only changes what the firmware asks for. The DT
    # reserved-memory region still has to shrink, otherwise Linux keeps the
    # unused tail of the old carveout locked out. Append a board-level override
    # so it wins over both the base ipq6018.dtsi and ipq6018-512m.dtsi include.
    q6_override = (
        "\n"
        f"&q6_region {{\n"
        f"\treg = <0x0 0x4ab00000 0x0 {q6_size}>;\n"
        f"}};\n"
    )
    q6_match = Q6_REGION_RE.search(text)
    if q6_match:
        q6_block = q6_match.group(0)
        q6_block = re.sub(
            r'reg\s*=\s*<[^;]+>;',
            f'reg = <0x0 0x4ab00000 0x0 {q6_size}>;',
            q6_block,
            count=1,
        )
        text = text[:q6_match.start()] + q6_block + text[q6_match.end():]
    else:
        text = text.rstrip() + q6_override

    dts_path.write_text(text)

    final = dts_path.read_text()
    pcie_final = _find_pcie_wifi_block(final)
    if not pcie_final:
        sys.exit("ERROR: PCIe wifi node disappeared from DTS after patching")
    ahb_final = AHB_BLOCK_RE.search(final)
    if not ahb_final:
        sys.exit("ERROR: &wifi block disappeared from DTS after patching")
    _verify_block('PCIe wifi (QCN9074 6 GHz)', pcie_final.group(0), mode)
    _verify_block('&wifi (AHB / IPQ6018 2.4+5 GHz)', ahb_final.group(0), mode)
    _verify_q6_region(final, q6_size)


def _verify_block(label: str, block: str, mode: int) -> None:
    found = MODE_RE.search(block)
    if not found:
        sys.exit(f"ERROR: {label} has no fw-memory-mode property after patching")
    if found.group(1) != str(mode):
        sys.exit(f"ERROR: {label} ended up with fw-memory-mode = <{found.group(1)}>, "
                 f"expected <{mode}>")


def _verify_q6_region(text: str, q6_size: str) -> None:
    matches = Q6_REGION_RE.findall(text)
    if not matches:
        sys.exit("ERROR: &q6_region override missing after patching")
    if not any(q6_size in block for block in matches):
        sys.exit(f"ERROR: &q6_region did not end up with size {q6_size}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument('--mode', type=int, required=True, choices=[0, 1, 2],
                        help='ath11k fw-memory-mode (0=1G, 1=512M, 2=256M)')
    parser.add_argument('--dts', type=pathlib.Path, required=True,
                        help='Path to ipq6018-mr7500.dts')
    args = parser.parse_args()

    if not args.dts.exists():
        sys.exit(f"ERROR: DTS not found at {args.dts}")

    patch_dts(args.dts, args.mode)
    print(f"OK: pinned qcom,ath11k-fw-memory-mode = <{args.mode}> "
          f"on both wifi nodes and q6_region size = {Q6_REGION_SIZES[args.mode]} "
          f"in {args.dts}")


if __name__ == "__main__":
    main()
