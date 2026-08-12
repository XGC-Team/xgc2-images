#!/usr/bin/env bash
set -euo pipefail
. /etc/os-release
test "${VERSION_CODENAME}" = "jammy"
/usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh
set +u
source /opt/ros/humble/setup.bash
set -u
test "${ROS_DISTRO}" = "humble"
command -v rviz2 >/dev/null
if dpkg-query -W -f='${Package}\n' | grep -E '^(lib)?xgc2-|ros-[a-z]+-xgc2-'; then
  echo "XGC2 packages leaked into build image" >&2
  exit 1
fi
