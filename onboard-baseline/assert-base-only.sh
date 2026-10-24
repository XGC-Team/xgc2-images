#!/usr/bin/env bash
# Validate installed package state, including transitive dependencies.
set -euo pipefail
if grep -R -E 'xgc2\.apt|xgc2-apt' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
  echo 'Robot base images must not configure XGC2 APT.' >&2
  exit 1
fi
packages="$(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n')"
if awk '$2 == "installed" {sub(/:[^:]+$/, "", $1); print $1}' <<<"$packages" \
  | grep -E '^(xsim$|libxgc2|xgc2-|ros-[a-z0-9]+-(xgc2-|sss-|scout-|wheeltec-|livox-|px4-multirotor-controller|ugv-controller|velodyne-driver|ouster-ros)|scout-msgs$|swarm-ros-bridge$|livox-ros-driver$|nvidia-(driver|dkms|jetpack)|linux-image-)'; then
  echo 'Robot base images must not contain XGC2 products or physical drivers.' >&2
  exit 1
fi
