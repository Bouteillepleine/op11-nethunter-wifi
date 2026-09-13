# OP11 NetHunter Wi-Fi

Wi-Fi injection toolkit for the OnePlus 11 as a KernelSU/Magisk module: 49 drivers,
firmware, a bundled userland and a WebUI.

**Use it on networks you own or have written permission to test.** It transmits:
deauthentication frames and PMKID solicitation are not passive, and in most places
pointing them at someone else's network is a criminal offence.

Bundled binaries and firmware are third-party — see [THIRD-PARTY.md](THIRD-PARTY.md). Several are GPL-licensed; corresponding source is linked there.

## Compatibility

Built and verified against:

| | |
|---|---|
| Device | OnePlus 11 — CPH2449, kalama / SM8550 |
| ROM | OxygenOS 16 (Android 16), `CPH2449_11.H.15_3150_202607172114` |
| Kernel | 5.15.180, `android13-5.15` GKI |
| ROM's cfg80211 | `vermagic=5.15.180-gef4e36add077 … modversions` |

**Any AK3 kernel for this device should work**, not just the one it was built with. The
modules need 468 kernel-core symbols and 96 from `cfg80211`. `cfg80211.ko` lives in
`vendor_dlkm` — the ROM, not the kernel zip — so flashing a different kernel does not
change it. The core symbols are KMI-stable: three independently built module sets
(OnePlus's own from `msm-kernel`, EmberHeart's, and this one) agree on **every** shared
core CRC — 224, 224 and 103 symbols, zero disagreements. Verified in practice by running
each set on the others' kernel.

It will **not** work on a kernel that:

- is built without `CONFIG_MODVERSIONS` — the vermagic string is then compared in full
- enforces module signatures with its own key
- sets `CONFIG_CFG80211=y` instead of `=m` — a built-in cfg80211 with different CRCs
- is a different version (6.x, or a SUBLEVEL with ABI changes)

To check any of this on the device itself, after flashing a kernel or taking a ROM update:

    sh wifi-ctl.sh verify            # or Tools -> Verify against this device

It reads the CRCs straight out of the live `/vendor_dlkm/lib/modules/cfg80211.ko` and
compares them with the shipped `mac80211.ko` — the same check CI runs, against whatever
ROM is actually installed rather than a recorded snapshot.

## Two things that are easy to get wrong

**`NL80211_TESTMODE` must match the vendor's value.** It guards two members *inside*
`struct cfg80211_ops`, so building `mac80211` with it off while the ROM's `cfg80211` has it
on shifts every op after `testmode_dump` — the stock cfg80211 then calls the wrong function
pointer at `wiphy_register` and the kernel panics as soon as a driver probes. TESTMODE
exports no symbol, so the shipped `cfg80211.ko` cannot be probed for it: take the value from
`msm-kernel/arch/arm64/configs/vendor/<soc>_GKI.config`.

**`hcxdumptool` is not passive.** Unfiltered it solicits every AP in range and collects
handshakes from networks that are not yours. `pmkid` therefore refuses to run without a
target BSSID, and pins the receive path to it with a compiled BPF.

## Firmware

Installed to `/mnt/vendor/persist/`, which `ueventd` searches natively — no mount, and no
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

rockyou is not bundled — 134 MB of generic public wordlist against a 12 MB module.
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
