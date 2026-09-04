#!/usr/bin/env bash
set -euo pipefail
. /etc/os-release
test "${VERSION_CODENAME}" = "noble"
command -v latexmk >/dev/null
command -v xelatex >/dev/null
command -v synctex >/dev/null
latexmk -v >/dev/null
xelatex -version >/dev/null
if dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E '^(lib)?xgc2-|ros-[a-z0-9]+-xgc2-'; then
  echo "XGC2 product packages must not be installed in the LaTeX toolchain image" >&2
  exit 1
fi
