#!/usr/bin/env bash
set -euo pipefail

if compgen -G "/etc/apt/sources.list.d/*xgc2*" >/dev/null; then
  echo "XGC2 APT source must not be present in build images" >&2
  ls -l /etc/apt/sources.list.d/*xgc2* >&2 || true
  exit 1
fi

if grep -R -E 'xgc2\.apt|xgc2-apt' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
  echo "XGC2 APT host must not be present in build images" >&2
  exit 1
fi

if dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E '^(lib)?xgc2-|ros-[a-z]+-xgc2-|ros-[a-z]+-sss-'; then
  echo "XGC2 product packages must not be installed in build images" >&2
  exit 1
fi
