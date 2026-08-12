#!/usr/bin/env bash
set -euo pipefail
. /etc/os-release
test "${VERSION_CODENAME}" = "bionic"
/usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh
source /opt/ros/melodic/setup.bash
test "${ROS_DISTRO}" = "melodic"
command -v rviz >/dev/null
command -v gazebo >/dev/null
if dpkg-query -W -f='${Package}\n' | grep -E '^(lib)?xgc2-|ros-[a-z]+-xgc2-'; then
  echo "XGC2 packages leaked into build image" >&2
  exit 1
fi
