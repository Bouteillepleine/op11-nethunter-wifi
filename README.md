# OP15 NetHunter Wi-Fi (branch `OP15`)

Wi-Fi toolkit for the OnePlus 15 as a KernelSU/Magisk module: 33 drivers, firmware,
a bundled userland and a WebUI. **This branch is never released.**

**Use it on networks you own or have written permission to test.**

## Why there is no release

Monitor mode and passive capture work. **Transmitting does not**: any TX panics the
kernel. Measured on this device 2026-09-13 with kernel `6.12.23-android16-5` - at
1T1R, VHT off and 5 dBm, the smallest transmit the hardware can do, it still
panicked. So `scan`, `deauth` and `pmkid` refuse by default; `NH_ALLOW_TX=1`
overrides, and will take the phone down.

lwfinger's rtw88 is not a way round it. Built for this kernel and gate-checked
clean (1115 symbols, 0 mismatched), it probes, loads firmware 52.14.0, and then the
adapter leaves the USB bus - no panic, but no interface either. The same adapter and
the same rtw88 driver inject fine on the OP11, so the fault is this phone's
USB/xHCI/OTG side, not the driver.

## Compatibility

| | |
|---|---|
| Device | OnePlus 15 (CPH2747, canoe / SM8850) |
| ROM | OxygenOS 16 (Android 16), `CPH2747_11.A.46_0460_202607312129` |
| Kernel | 6.12.23, `android16-6.12` GKI |
| ROM's stack | `vermagic=6.12.23-android16-5-o-gfaa122b439b2-4k` |

This module ships **no `mac80211.ko`**: `wonder` and `qca_cld3_peach_v2` are bound to
the ROM's, so the drivers are built to load against it. CI enforces that.

    sh wifi-ctl.sh verify      # checks the drivers against the live stack

## Two things that are easy to get wrong

**`NL80211_TESTMODE` must match the vendor's value.** It guards two members *inside*
`struct cfg80211_ops`, so building `mac80211` with it off while the ROM's `cfg80211` has it
on shifts every op after `testmode_dump`, the stock cfg80211 then calls the wrong function
pointer at `wiphy_register` and the kernel panics as soon as a driver probes. TESTMODE
exports no symbol, so the shipped `cfg80211.ko` cannot be probed for it: take the value from
`msm-kernel/arch/arm64/configs/vendor/<soc>_GKI.config`.

**`hcxdumptool` is not passive.** Unfiltered it solicits every AP in range and collects
handshakes from networks that are not yours. `pmkid` therefore refuses to run without a
target BSSID, and pins the receive path to it with a compiled BPF.

## Firmware

Installed to `/mnt/vendor/persist/`, which `ueventd` searches natively: no mount, and no
dependence on the module tree being served. A `firmware_class` path inside the module
directory cannot work: the kernel SELinux domain may not read anything under `/data`, so the
load fails with `-13` and no AVC is logged. `uninstall.sh` removes exactly what it added.

## Usage

Open the module's WebUI, or drive the backend directly:

    sh wifi-ctl.sh startmon                       # matching driver + monitor mode
    sh wifi-ctl.sh scan wlan1                     # works from monitor; restores the mode
    sh wifi-ctl.sh capture wlan1 40               # -> /data/adb/nethunter-captures
    sh wifi-ctl.sh deauth wlan1 <bssid> <ch>
    sh wifi-ctl.sh pmkid wlan1 <bssid>            # refuses without a target
    sh wifi-ctl.sh hashes <capture>               # -> .hc22000 for hashcat -m 22000
    sh wifi-ctl.sh crack <capture> [wordlist]     # bundled aircrack-ng, on device
    sh wifi-ctl.sh getwordlist                    # fetch rockyou to /sdcard/Download

rockyou is not bundled: 134 MB of generic public wordlist against a 12 MB module.
`getwordlist` pulls it with the phone's own curl, or drop a `rockyou.txt`/`rockyou.txt.gz`
into `/sdcard/Download` yourself (the .gz is gunzipped on first use). On-device cracking is
CPU-only; for a full wordlist use `hashes` and run hashcat on a PC.

A capture with no client is a capture with no handshake. Deauth only helps if the station
honours it; forcing a device you control to re-associate is more reliable.

## CI

    python3 tools/check-crcs.py mac80211.ko tools/device_cfg80211.symvers

The gate compares `mac80211.ko`'s `__versions` against the export CRCs read off the device's
own `cfg80211.ko`, then every driver against the `mac80211` it ships with. It exists because
a `mac80211` with the wrong `NL80211_TESTMODE` passed every other check, loaded cleanly, and
panicked the phone on first probe. It names that build:

    MISMATCH wiphy_new_nm    reference=0x03915fa5 built=0xd25c4ce2

`Sync modules from a kernel build` pulls the `.ko` files from a finished
`Bouteillepleine/OnePlus-KsuNext_NMS` run (branch `nethunter-op11`), re-runs the gate and
opens a PR only if it passes. Needs a `KERNEL_REPO_TOKEN` secret, since `GITHUB_TOKEN`
cannot read another repository.
