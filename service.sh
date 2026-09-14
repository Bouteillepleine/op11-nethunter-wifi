MODDIR=${0%/*}
[ -f "$MODDIR/auto_load" ] || exit 0
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 1; done
for ko in "$MODDIR"/drivers/*.ko; do insmod "$ko" 2>/dev/null; done
