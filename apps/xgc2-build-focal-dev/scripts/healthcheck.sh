#!/usr/bin/env bash
set -euo pipefail
. /etc/os-release
test "${VERSION_CODENAME}" = "focal"
/usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh
command -v g++ >/dev/null
command -v cmake >/dev/null
command -v dpkg-buildpackage >/dev/null
command -v jq >/dev/null
command -v node >/dev/null
command -v pnpm >/dev/null
command -v uv >/dev/null
command -v rustc >/dev/null
command -v cargo >/dev/null
command -v go >/dev/null
command -v gh >/dev/null
command -v buf >/dev/null
command -v rg >/dev/null
python3 -c 'import yaml,numpy'
node -v | grep -q '^v22'
command -v skopeo >/dev/null
command -v bun >/dev/null
command -v yarn >/dev/null
if dpkg-query -W -f='${Package}\n' | grep -E '^(lib)?xgc2-|ros-[a-z]+-xgc2-'; then
  echo "XGC2 packages leaked into build image" >&2
  exit 1
fi
