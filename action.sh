MODDIR=${0%/*}
echo "[*] Loading Nethunter Wi-Fi injection drivers..."
n=0
for ko in "$MODDIR"/drivers/*.ko; do
  name=$(basename "$ko" .ko)
  if lsmod | grep -q "^${name} "; then
    echo "    - ${name}: already loaded"
  elif insmod "$ko" 2>/dev/null; then
    echo "    - ${name}: loaded"; n=$((n+1))
  else
    echo "    - ${name}: FAILED (check: dmesg | tail)"
  fi
done
echo "[*] ${n} driver(s) newly loaded. Now plug your USB adapter:"
echo "    ip link            # look for wlanX"
echo "    airmon-ng start wlanX"
