#!/usr/bin/env bash
# Check installed runtime entrypoints without starting a service or simulator.
set -euo pipefail
while IFS= read -r specification; do
  package="${specification%%=*}"
  version="${specification#*=}"
  actual="$(dpkg-query -W -f='${Version}' "$package")"
  [[ "$actual" == "$version" ]] || { echo "Unexpected $package version: $actual" >&2; exit 1; }
done < /opt/xgc2/onboard-baseline/simulation-packages.txt
for file in \
  /opt/ros/noetic/lib/gazebo_sim_fs150_sitl/start_sitl.py \
  /opt/ros/noetic/lib/vrpn_client_ros/vrpn_tracker_node \
  /opt/ros/noetic/lib/mavros/mavros_node; do
  test -x "$file"
done
test -d /opt/ros/noetic/share/px4_sitl_1_12/runtime
test -s /opt/ros/noetic/share/gazebo_sim_fs150_sitl/config/generated/fs150-sitl.params
test -x /sbin/init
