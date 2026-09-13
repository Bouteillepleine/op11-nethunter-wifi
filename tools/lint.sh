#!/usr/bin/env bash
# Everything that has silently broken this module at least once.
set -uo pipefail
cd "$(dirname "$0")/.."
rc=0
for f in action.sh customize.sh post-fs-data.sh service.sh uninstall.sh wifi-ctl.sh tools/*.sh; do
  sh -n "$f" || { echo "SYNTAX: $f"; rc=1; }
done
# A CRLF update-binary or customize.sh makes the module fail to install.
while IFS= read -r f; do
  if grep -qU $'\r' "$f" 2>/dev/null; then echo "CRLF: $f"; rc=1; fi
done < <(git ls-files '*.sh' 'META-INF/*' 'module.prop' 'webroot/*')
# The WebUI calling another device's module id was invisible until a screenshot.
if grep -q "op15_nethunter_wifi" webroot/index.html; then
  echo "WEBUI: hardcoded op15 module path"; rc=1
fi
# Every command the UI calls must exist in the backend.
missing=$(comm -23 \
  <(grep -oE 'exec\(("|`)[a-z0-9]+' webroot/index.html | sed -E 's/exec\(("|`)//' | sort -u) \
  <(grep -oE '^  [a-z0-9|]+\)' wifi-ctl.sh | tr -d ' )' | tr '|' '\n' | sort -u))
if [ -n "$missing" ]; then echo "WEBUI calls commands the backend lacks: $missing"; rc=1; fi
id=$(sed -n 's/^id=//p' module.prop)
[ "$id" = "op11_nethunter_wifi" ] || { echo "module.prop id changed: $id"; rc=1; }
[ "$rc" = 0 ] && echo "lint: clean"
exit $rc
