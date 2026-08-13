#!/usr/bin/env bash
set -euo pipefail
. /etc/os-release
test "${VERSION_CODENAME}" = "noble"
/usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh
command -v g++ >/dev/null
command -v cmake >/dev/null
command -v dpkg-buildpackage >/dev/null
python3 -c 'import yaml,numpy'
if dpkg-query -W -f='${Package}\n' | grep -E '^(lib)?xgc2-|ros-[a-z]+-xgc2-'; then
  echo "XGC2 packages leaked into build image" >&2
  exit 1
fi
