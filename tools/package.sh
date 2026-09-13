#!/usr/bin/env bash
# Build the flashable zip from the working tree. Same layout the module expects,
# LF line endings on everything a shell or the installer has to read.
set -euo pipefail
cd "$(dirname "$0")/.."
ver=$(sed -n 's/^version=//p' module.prop)
out="${1:-op11-nethunter-wifi-$ver.zip}"
rm -f "$out"
zip -r -X -q "$out" \
  META-INF action.sh customize.sh post-fs-data.sh service.sh uninstall.sh \
  wifi-ctl.sh module.prop webroot bin drivers system mac80211.ko
echo "$out  $(du -h "$out" | cut -f1)  $(unzip -l "$out" | tail -1 | awk '{print $2}') entries"
