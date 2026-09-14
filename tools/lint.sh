#!/usr/bin/env bash
# Everything that has silently broken a module at least once.
# usage: tools/lint.sh [module-dir]   (default: repo root = the OP11 module)
set -uo pipefail
cd "$(dirname "$0")/.."
D="${1:-.}"
rc=0
say() { echo "[$(sed -n 's/^id=//p' "$D/module.prop" 2>/dev/null || echo module)] $*"; }

for f in action.sh customize.sh post-fs-data.sh service.sh uninstall.sh wifi-ctl.sh; do
  [ -f "$D/$f" ] || continue
  sh -n "$D/$f" || { say "SYNTAX(sh): $f"; rc=1; }
done
for f in tools/*.sh; do
  bash -n "$f" || { say "SYNTAX(bash): $f"; rc=1; }
done

# A CRLF update-binary or customize.sh makes the module fail to install.
while IFS= read -r f; do
  grep -qU $'\r' "$f" 2>/dev/null && { say "CRLF: $f"; rc=1; }
done < <(git ls-files "$D/*.sh" "$D/META-INF/*" "$D/module.prop" "$D/webroot/*" 2>/dev/null)

# The WebUI calling another device's module id was invisible until a screenshot.
if grep -qE 'const CTL="sh /data/adb/modules/op[0-9]+_' "$D/webroot/index.html" 2>/dev/null; then
  say "WEBUI: CTL hardcodes one module id instead of resolving at runtime"; rc=1
fi

# Every command the UI calls must exist in the backend.
if [ -f "$D/webroot/index.html" ] && [ -f "$D/wifi-ctl.sh" ]; then
  missing=$(comm -23 \
    <(grep -oE 'exec\(("|`)[a-z0-9]+' "$D/webroot/index.html" | sed -E 's/exec\(("|`)//' | sort -u) \
    <(grep -oE '^  [a-z0-9|]+\)' "$D/wifi-ctl.sh" | tr -d ' )' | tr '|' '\n' | sort -u))
  [ -n "$missing" ] && { say "WEBUI calls commands the backend lacks: $missing"; rc=1; }
fi

# A module that ships its own mac80211 must swap it in on EVERY load path, not
# just at boot: loading a driver against the stock one fails on the
# __ieee80211_*_led_* symbols. Reported by a tester 2026-09-14.
if [ -f "$D/mac80211.ko" ]; then
  for cmd in "loadmatch)" "startmon)" "load)"; do
    awk -v c="$cmd" 'index($0,"  "c){f=1} f&&/_swap_mac80211/{ok=1} f&&/;;$/{exit} END{exit !ok}' \
      "$D/wifi-ctl.sh" || { say "LOADPATH: $cmd does not call _swap_mac80211"; rc=1; }
  done
fi

id=$(sed -n 's/^id=//p' "$D/module.prop")
case "$id" in op1[15]_nethunter_wifi) ;; *) say "unexpected module id: $id"; rc=1;; esac
[ "$rc" = 0 ] && say "lint: clean"
exit $rc
