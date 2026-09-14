ui_print "  OP15 Nethunter Wi-Fi injection drivers"
ui_print "  - RTL 8812au/8821au/88x2bu USB adapters"
ui_print "  - Bundled static iw 6.17 (no chroot needed)"
ui_print "  - Open the module WebUI: 1-tap monitor, scan,"
ui_print "    MAC spoof, channel/txpower/region, power-save"
OLDCAP=/data/adb/modules/op15_nethunter_wifi/captures
NEWCAP=/data/adb/nethunter-captures
mkdir -p "$NEWCAP"
if [ -d "$OLDCAP" ]; then
  cp -a "$OLDCAP"/. "$NEWCAP"/ 2>/dev/null
  ui_print "  - captures moved to $NEWCAP (updates no longer erase them)"
fi
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/drivers" 0 0 0755 0644
set_perm "$MODPATH/wifi-ctl.sh" 0 0 0755
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
set_perm_recursive "$MODPATH/system" 0 0 0755 0644 u:object_r:system_file:s0
ui_print "  - firmware ships at /system/etc/firmware (a firmware_class"
ui_print "    path under /data cannot be read by the kernel domain)"
# Firmware also goes on the persist partition. ueventd searches
# /mnt/vendor/persist/<name> natively, it is writable and it survives reboots,
# so the blobs load with no mount at all and without depending on the module
# tree being served.
PFW=/mnt/vendor/persist
AVAIL=$(df -k "$PFW" 2>/dev/null | tail -1 | tr -s " " | cut -d" " -f4)
NEED=$(du -sk "$MODPATH/system/etc/firmware" 2>/dev/null | cut -f1)
if [ -d "$PFW" ] && [ "${AVAIL:-0}" -gt $(( ${NEED:-0} + 4096 )) ]; then
  cp -a "$MODPATH/system/etc/firmware/." "$PFW"/ 2>/dev/null
  find "$PFW" -newer "$MODPATH/module.prop" -type d -exec chmod 755 {} + 2>/dev/null
  find "$PFW" -newer "$MODPATH/module.prop" -type f -exec chmod 644 {} + 2>/dev/null
  ui_print "  - firmware copied to $PFW (no mount needed)"
else
  ui_print "  - SKIPPED persist firmware copy (need ${NEED}k, have ${AVAIL}k)"
fi
set_perm_recursive "$MODPATH/system" 0 0 0755 0644 u:object_r:system_file:s0
