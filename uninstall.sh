PFW=/mnt/vendor/persist
for d in rtw88 mediatek; do rm -rf "$PFW/$d"; done
for f in carl9170-1.fw htc_7010.fw htc_9271.fw mt7601u.bin mt7662.bin mt7662_rom_patch.bin rt2870.bin; do
  rm -f "$PFW/$f"
done
