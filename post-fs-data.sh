MODDIR=${0%/*}
# Firmware ships as system/etc/firmware/... so magic mount exposes it at
# /etc/firmware, which is already in ueventd's search list. The module dir
# itself is useless as a firmware_class path: the kernel domain cannot read
# anything under /data, so a direct load from there returns -13 (EACCES) and
# no AVC is logged because it is dontaudited.
if [ -d /system/etc/firmware ]; then
  echo /system/etc/firmware > /sys/module/firmware_class/parameters/path 2>/dev/null
fi
# drivers still load on demand (action.sh) or via service.sh opt-in
