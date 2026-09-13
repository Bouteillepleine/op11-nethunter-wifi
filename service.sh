# OP11 NetHunter Wi-Fi
# Copyright (C) 2026 Bouteillepleine
# SPDX-License-Identifier: GPL-2.0-or-later
MODDIR=${0%/*}
[ -f "$MODDIR/auto_load" ] || exit 0
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 1; done

# Swap in our mac80211 so the drivers resolve against the one they were built
# with. The layouts are in fact identical - net/mac80211 is the same source in
# both trees - but the CRCs are not, and ath9k force-selects MAC80211_LEDS,
# whose five symbols the stock mac80211 does not export.
# cfg80211 is NOT replaced: kiwi_v2 holds it, and ours is built from
# msm-kernel's cfg80211.h with the vendor's CONFIG_CFG80211_* values so the
# CRCs line up. NL80211_TESTMODE in particular must match: it guards two
# members inside struct cfg80211_ops.
if [ -f "$MODDIR/mac80211.ko" ]; then
  lsmod | grep -q '^wonder ' && rmmod wonder 2>/dev/null
  if rmmod mac80211 2>/dev/null; then
    insmod "$MODDIR/mac80211.ko" 2>/dev/null && log -t nethunter "swapped in our mac80211"
  fi
fi

# Three passes: these are a dependency chain (rtw_core <- rtw_usb <- rtw_88xxa
# <- rtw_8812a <- rtw_8812au) and a single alphabetical pass would load them
# out of order and fail.
for pass in 1 2 3; do
  for ko in "$MODDIR"/drivers/*.ko; do insmod "$ko" 2>/dev/null; done
done
