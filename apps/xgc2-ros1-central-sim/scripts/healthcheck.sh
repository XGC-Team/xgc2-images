#!/usr/bin/env bash
set -euo pipefail

export ROS_MASTER_URI="${ROS_MASTER_URI:-http://127.0.0.1:11311}"
source /opt/ros/noetic/setup.bash

test "$(rosversion -d)" = "noetic"
command -v roscore >/dev/null
command -v gzserver >/dev/null
command -v gzclient >/dev/null
command -v rviz >/dev/null
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
  gazebo_sim_mecanum
  xgc2_geometry_msgs
  ros_image_rtp_adapter
  xgc_ros1_tools_adapter
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
test -f /opt/ros/noetic/lib/libgazebo_sim_mecanum_contract.so
test -x /opt/ros/noetic/lib/xgc_px4_multirotor_ros1_adapter/xgc_px4_multirotor_ros1_adapter_node
test -x /opt/ros/noetic/lib/xgc_scout_mini_ros1_adapter/xgc_scout_mini_ros1_adapter_node
test -x /opt/ros/noetic/lib/xgc_mecanum_ugv_ros1_adapter/xgc_mecanum_ugv_ros1_adapter_node
test -x /opt/ros/noetic/lib/ros_image_rtp_adapter/image_rtp_adapter
test -x /opt/ros/noetic/lib/xgc_ros1_tools_adapter/xgc_ros1_tools_adapter_node
test -x /opt/ros/noetic/lib/xgc_ros1_tools_adapter/xgc_ros1_tools_adapter_service_helper
test -x /usr/bin/xgc-media-edge
test -x /usr/lib/xgc2-media-edge/mediamtx

linked_artifacts=(
  /usr/bin/gzserver-11.15.1
  /usr/bin/gzclient-11.15.1
  /opt/ros/noetic/lib/rviz/rviz
  /opt/ros/noetic/lib/libgazebo_scene_contract.so
  /opt/ros/noetic/lib/libgazebo_sim_mecanum_contract.so
  /opt/ros/noetic/lib/xgc_ros1_tools_adapter/xgc_ros1_tools_adapter_node
  /opt/qgroundcontrol/appdir/QGroundControl
  /usr/bin/xgc-media-edge
  /usr/lib/xgc2-media-edge/mediamtx
)

for artifact in "${linked_artifacts[@]}"; do
  test -e "${artifact}"
  if ldd "${artifact}" 2>&1 | grep -q 'not found'; then
    echo "unresolved dynamic dependency in ${artifact}" >&2
    ldd "${artifact}" >&2
    exit 1
  fi
done

for forbidden_package in \
  xgc2-agent \
  ros-noetic-xgc2-b2arx-description \
  ros-noetic-xgc2-unitree-b2-adapter \
  ros-noetic-xgc2-mocap-rotor-adapter \
  ros-noetic-xgc2-mocap-rotor-forwarder; do
  if dpkg-query -W "${forbidden_package}" >/dev/null 2>&1; then
    echo "forbidden package is installed: ${forbidden_package}" >&2
    exit 1
  fi
done

test "$(dpkg --print-architecture)" = "amd64"

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
