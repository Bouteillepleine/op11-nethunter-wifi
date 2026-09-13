MODDIR=${0%/*}
echo "[*] Loading Nethunter Wi-Fi injection drivers..."
# rtw_8812au needs rtw_core, rtw_usb, rtw_88xxa and rtw_8812a first, and a
# single alphabetical pass loads them in the wrong order and reports FAILED
# for everything that has a dependency. Keep going while anything still loads.
n=0; changed=1
while [ "$changed" = 1 ]; do
  changed=0
  for ko in "$MODDIR"/drivers/*.ko; do
    name=$(basename "$ko" .ko)
    lsmod | grep -q "^${name} " && continue
    if insmod "$ko" 2>/dev/null; then changed=1; n=$((n+1)); fi
  done
done
f=0
for ko in "$MODDIR"/drivers/*.ko; do
  name=$(basename "$ko" .ko)
  lsmod | grep -q "^${name} " || { echo "    - ${name}: FAILED (check: dmesg | tail)"; f=$((f+1)); }
done
echo "[*] ${n} driver(s) newly loaded, ${f} failed. Now plug your USB adapter:"
echo "    open the module WebUI and tap Start Monitor Mode,"
echo "    or: sh $MODDIR/wifi-ctl.sh startmon"
