# Bundled third-party components

This module redistributes binaries and firmware it did not author. Sources and licences
below; where provenance is inherited rather than built here, that is said plainly.

## Kernel modules — GPL-2.0

`mac80211.ko` and the 49 modules in `drivers/` are built from the Linux kernel. Corresponding
source: the GKI tree in the manifest of
[Bouteillepleine/OnePlus-KsuNext_NMS](https://github.com/Bouteillepleine/OnePlus-KsuNext_NMS)
(public), branch `nethunter-op11`, which records the exact trees, revisions and config used.
The rtw88 drivers come from [lwfinger/rtw88](https://github.com/lwfinger/rtw88).

## Userland in `bin/`

| binary | upstream | licence |
|---|---|---|
| `hcxpcapngtool` | [ZerBea/hcxtools](https://github.com/ZerBea/hcxtools) | MIT |
| `kocrc` | `tools/kocrc.c` in this repo | same as this repo |
| `hcxdumptool` | [ZerBea/hcxdumptool](https://github.com/ZerBea/hcxdumptool) | MIT |
| `aircrack-ng` | [aircrack-ng](https://github.com/aircrack-ng/aircrack-ng) | GPL-2.0 |
| `mdk4` | [aircrack-ng/mdk4](https://github.com/aircrack-ng/mdk4) | GPL-2.0 |
| `iw` | kernel.org `iw` | ISC |
| `tcpdump` | [the-tcpdump-group/tcpdump](https://github.com/the-tcpdump-group/tcpdump) | BSD-3-Clause |
| `ffmpeg` | [FFmpeg](https://github.com/FFmpeg/FFmpeg) | LGPL-2.1+ / GPL-2.0+ depending on build |
| `camscan`, `v4lgrab` | small helpers carried over from the OP15 module | unstated upstream |

`hcxpcapngtool` and `kocrc` were built here, statically for aarch64 with
`aarch64-linux-gnu-gcc` (hcxpcapngtool against a cross-built OpenSSL 3.0.15 + zlib).
**The rest were inherited as prebuilt binaries from the OP15 NetHunter module and their exact
build provenance is not known to this repository.** If you need verified provenance, rebuild
them from the upstreams above rather than trusting these.

Several are GPL-licensed. Redistributing them carries an obligation to offer the
corresponding source; the upstream links are given for that reason, but anyone redistributing
this repo further should satisfy themselves that it is met for their use.

## Firmware in `system/etc/firmware/`

Realtek (`rtw88/`), Atheros (`htc_*.fw`, `carl9170-1.fw`) and MediaTek (`mt76*`, `mediatek/`,
`rt2870.bin`) blobs, as distributed in
[linux-firmware](https://gitlab.com/kernel-firmware/linux-firmware). Proprietary, redistributable
under the vendor terms in that repository's `WHENCE` and `LICENCE.*` files. No firmware here is
modified.
