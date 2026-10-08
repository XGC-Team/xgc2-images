#!/usr/bin/env bash
set -euo pipefail

source /opt/ros/noetic/setup.bash
test "$(rosversion -d)" = "noetic"
test "${DISABLE_ROS1_EOL_WARNINGS:-}" = "1"
command -v roscore >/dev/null
command -v rviz >/dev/null
command -v gazebo >/dev/null
command -v git >/dev/null
command -v gdb >/dev/null
command -v glxinfo >/dev/null
dpkg-query -W libomp5-10 >/dev/null
test -x /opt/ros/noetic/lib/mavros/mavros_node
