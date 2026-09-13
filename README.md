# OP11 NetHunter Wi-Fi

Wi-Fi injection toolkit for the OnePlus 11 (CPH2449, kalama/SM8550, kernel 5.15.180) as a
KernelSU/Magisk module: 49 in-tree Wi-Fi drivers, firmware, a bundled userland and a WebUI.

Use it on networks you own or are authorised to test.

## What is in it

| | |
|---|---|
| `mac80211.ko` | built against the device's own cfg80211 export CRCs, swapped in at boot |
| `drivers/` | 49 drivers — rtw88 (lwfinger), ath9k_htc, carl9170, mt76, mt7601u, rt2800usb |
| `system/etc/firmware/` | Realtek / Atheros / MediaTek blobs |
| `bin/` | iw, mdk4, tcpdump, hcxdumptool, hcxpcapngtool, aircrack-ng, ffmpeg, v4lgrab, camscan |
| `webroot/` | the WebUI (Home / Radio / Attack / Cam / Keys / Tools / Help, EN-FR-DE-ES-IT) |
| `wifi-ctl.sh` | the backend every button calls; usable on its own over adb |

## Two things that are easy to get wrong

**`NL80211_TESTMODE` must match the vendor's value.** It guards two members *inside*
`struct cfg80211_ops`, so building `mac80211` with it off while the device's `cfg80211` has it
on shifts every op after `testmode_dump` — the stock cfg80211 then calls the wrong function
pointer at `wiphy_register` and the kernel panics as soon as a driver probes. TESTMODE exports
no symbol, so the shipped `cfg80211.ko` cannot be probed for it: take the value from
`msm-kernel/arch/arm64/configs/vendor/<soc>_GKI.config`.

**`hcxdumptool` is not passive.** Unfiltered it solicits every AP in range and will collect
handshakes from networks that are not yours. `pmkid` therefore refuses to run without a target
BSSID, and pins the receive path to it with a compiled BPF.

## Firmware

Installed to `/mnt/vendor/persist/`, which `ueventd` searches natively — no mount, and no
dependence on the module tree being served. A `firmware_class` path inside the module directory
cannot work: the kernel SELinux domain may not read anything under `/data`, so the load fails
with `-13` and no AVC is logged. `uninstall.sh` removes exactly what was added.

## Usage

Open the module's WebUI, or drive it directly:

    sh wifi-ctl.sh startmon                       # load matching driver + monitor mode
    sh wifi-ctl.sh scan wlan1                     # works from monitor; restores the mode
    sh wifi-ctl.sh capture wlan1 40               # -> /data/adb/nethunter-captures
    sh wifi-ctl.sh deauth wlan1 <bssid> <ch>
    sh wifi-ctl.sh pmkid wlan1 <bssid>            # refuses without a target
    sh wifi-ctl.sh hashes <capture>               # -> .hc22000 for hashcat -m 22000
    sh wifi-ctl.sh crack <capture> [wordlist]     # bundled aircrack-ng, on device

A capture with no client is a capture with no handshake. Deauth only helps if the station
honours it; forcing a device you control to re-associate is more reliable.

## Building the modules

Kernel and modules come from `Bouteillepleine/OnePlus-KsuNext_NMS`, branch `nethunter-op11`.

## CI

`tools/lint.sh` and `tools/check-crcs.py` run on every push.

The CRC gate is the one that matters. It parses the `__versions` table out of
`mac80211.ko` and compares each cfg80211 symbol against `tools/device_cfg80211.symvers`
— the export CRCs read straight off the device's own `/vendor_dlkm/lib/modules/cfg80211.ko`.
Every driver is then checked against the `mac80211.ko` it ships with. Run it by hand with:

    python3 tools/check-crcs.py mac80211.ko tools/device_cfg80211.symvers

This exists because a `mac80211` built with the wrong `NL80211_TESTMODE` passed every
other check, loaded cleanly, and then panicked the phone the moment a driver registered
a wiphy. The gate catches that build by name:

    MISMATCH wiphy_new_nm    reference=0x03915fa5 built=0xd25c4ce2

`Sync modules from a kernel build` pulls the 50 `.ko` files from a finished
`OnePlus-KsuNext_NMS` run, re-runs the gate and opens a PR only if it passes. It needs a
`KERNEL_REPO_TOKEN` secret — a PAT that can read that repo, since `GITHUB_TOKEN` cannot
reach across repositories.
