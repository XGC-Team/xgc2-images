#!/usr/bin/env bash
set -euo pipefail

export ROS_MASTER_URI="${ROS_MASTER_URI:-http://127.0.0.1:11311}"
source /opt/ros/noetic/setup.bash

test "$(rosversion -d)" = "noetic"
command -v roscore >/dev/null
command -v gzserver >/dev/null
command -v socat >/dev/null
command -v qgroundcontrol >/dev/null
command -v xgc-process-launcher >/dev/null
command -v xgc-process-runner >/dev/null
command -v setsid >/dev/null
command -v flock >/dev/null
test "$(cat /opt/qgroundcontrol/VERSION)" = "4.4.4"
test "$(cat /opt/qgroundcontrol/APPIMAGE_SHA256)" = \
  "c0356bfed3ca1c02fafd36d3168cd532590a894c787d612aa237a0cfc0b48580"
test -x /opt/qgroundcontrol/appdir/AppRun
grep -a -q 'v4\.4\.4' /opt/qgroundcontrol/appdir/QGroundControl

required_ros_packages=(
  xgc2_gazebo_scene
  xgc2_robot_visualization
  gazebo_sim_visualization
  gazebo_sim_vrpn_bridge
  gazebo_sim_worlds
  gazebo_sim_scout
  px4_sitl_1_12
  gazebo_sim_px4_1_12
  gazebo_sim_fs150_sitl
)

for package in "${required_ros_packages[@]}"; do
  rospack find "${package}" >/dev/null
done

test -x \
  /opt/ros/noetic/lib/xgc2_robot_visualization/xgc2_robot_description_publisher_node
test -f /opt/ros/noetic/lib/libgazebo_scene_contract.so

lock_file=/usr/share/xgc2-central-sim/packages.lock
test -s "${lock_file}"

while IFS= read -r entry; do
  entry="${entry%%#*}"
  entry="${entry//[[:space:]]/}"
  [[ -z "${entry}" ]] && continue

  package="${entry%%=*}"
  expected_version="${entry#*=}"
  installed_version="$(dpkg-query -W -f='${Version}' "${package}")"
  test "${installed_version}" = "${expected_version}"
done <"${lock_file}"
