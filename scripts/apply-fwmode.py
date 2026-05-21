#!/usr/bin/env python3
"""Patch ipq6018-mr7500.dts to pin qcom,ath11k-fw-memory-mode.

The MR7500 has three ath11k radios spread across two DTS nodes:

  - 2.4/5 GHz: on the IPQ6018 internal Q6/WCSS over AHB, node `&wifi`
  - 6 GHz:     QCN9074 over PCIe,                       node `&pcie0/bridge@0,0/wifi@1,0`

Upstream openwrt commit a1bf306bb71 sets fw-memory-mode = <1> on the AHB
`&wifi` node only, leaving the PCIe `wifi@1,0` to fall through to the ath11k
driver's default (mode 0 / ~1 GB profile). On a 512 MB MR7500 that pins
~85 MB of host-firmware carveout to the 6 GHz radio. This script overrides
both nodes to the requested mode so each CI artifact has a coherent meaning.

Modes (per ath11k upstream conventions):
  0 = ~1 GB profile  (512 peers, 17 vdevs per radio)
  1 = 512 MB profile (128 peers, 8 vdevs)  -- matches MR7500 RAM
  2 = 256 MB profile (128 peers, 8 vdevs, coldboot calibration disabled)
"""

import argparse
import pathlib
import re
import sys


PCIE_BLOCK_RE = re.compile(r'wifi@1,0\s*\{([^}]*)\}', re.DOTALL)
AHB_BLOCK_RE = re.compile(r'&wifi\s*\{([^}]*)\}', re.DOTALL)
MODE_RE = re.compile(r'qcom,ath11k-fw-memory-mode\s*=\s*<\s*(\d+)\s*>\s*;')


def patch_dts(dts_path: pathlib.Path, mode: int) -> None:
    text = dts_path.read_text()

    # Override any existing fw-memory-mode property (upstream sets it on &wifi).
    text = MODE_RE.sub(f'qcom,ath11k-fw-memory-mode = <{mode}>;', text)

    # If the PCIe wifi@1,0 node is missing the property, insert it after the
    # calibration-variant line we know exists upstream.
    pcie_match = PCIE_BLOCK_RE.search(text)
    if not pcie_match:
        sys.exit(f"ERROR: could not find wifi@1,0 block in {dts_path}")

    if 'qcom,ath11k-fw-memory-mode' not in pcie_match.group(1):
        injected = re.sub(
            r'(qcom,ath11k-calibration-variant\s*=\s*"Linksys-MR7500"\s*;)',
            rf'\1\n\t\t\tqcom,ath11k-fw-memory-mode = <{mode}>;',
            pcie_match.group(0),
            count=1,
        )
        if injected == pcie_match.group(0):
            sys.exit("ERROR: could not insert fw-memory-mode into wifi@1,0 "
                     "(calibration-variant anchor not found)")
        text = text[:pcie_match.start()] + injected + text[pcie_match.end():]

    dts_path.write_text(text)

    final = dts_path.read_text()
    _verify_node('wifi@1,0 (PCIe / QCN9074 6 GHz)', PCIE_BLOCK_RE, final, mode)
    _verify_node('&wifi (AHB / IPQ6018 2.4+5 GHz)', AHB_BLOCK_RE, final, mode)


def _verify_node(label: str, block_re: re.Pattern, text: str, mode: int) -> None:
    match = block_re.search(text)
    if not match:
        sys.exit(f"ERROR: {label} block disappeared from DTS after patching")
    found = MODE_RE.search(match.group(0))
    if not found:
        sys.exit(f"ERROR: {label} has no fw-memory-mode property after patching")
    if found.group(1) != str(mode):
        sys.exit(f"ERROR: {label} ended up with fw-memory-mode = <{found.group(1)}>, "
                 f"expected <{mode}>")


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
          f"on both wifi nodes in {args.dts}")


if __name__ == "__main__":
    main()
