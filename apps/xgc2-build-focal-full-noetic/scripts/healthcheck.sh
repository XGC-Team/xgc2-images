#!/usr/bin/env bash
set -euo pipefail
. /etc/os-release
test "${VERSION_CODENAME}" = "focal"
/usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh
set +u
source /opt/ros/noetic/setup.bash
set -u
test "${ROS_DISTRO}" = "noetic"
command -v rviz >/dev/null
command -v gazebo >/dev/null
dpkg-query -W ros-noetic-pcl-ros ros-noetic-pcl-conversions \
  ros-noetic-eigen-conversions ros-noetic-tf libgflags-dev \
  libgoogle-glog-dev libtbb-dev libyaml-cpp-dev libpcl-dev \
  libffmpeg-nvenc-dev nlohmann-json3-dev >/dev/null
if dpkg-query -W -f='${Package}\n' | grep -E '^(lib)?xgc2-|ros-[a-z]+-xgc2-'; then
  echo "XGC2 packages leaked into build image" >&2
  exit 1
fi
