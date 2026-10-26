#!/usr/bin/env bash
set -euo pipefail
/opt/xgc2/onboard-baseline/check-simulation.sh
test -s /usr/share/GeographicLib/geoids/egm96-5.pgm
set +u # ROS setup reads optional variables.
source /opt/ros/noetic/setup.bash
set -u
python3 -B -c "import rospy, zenoh"
/opt/xgc2/onboard-baseline/install-zenoh.sh check
dpkg-query -W libglpk40 >/dev/null
if [[ "$ONBOARD_IMAGE_ROLE" == builder ]]; then
  dpkg-query -W libglpk-dev >/dev/null
  for executable in gcc g++ make cmake ninja go dpkg-deb fakeroot file; do command -v "$executable" >/dev/null || { echo "Missing builder tool: $executable" >&2; exit 1; }; done
else
  # ROS packages may require CMake/headers transitively. Preserve declared dependencies.
  test ! -e /usr/local/go/bin/go
  test ! -d /usr/local/rustup
fi
