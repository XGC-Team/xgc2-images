#!/usr/bin/env bash
set -euo pipefail
/opt/xgc2/onboard-baseline/check-simulation.sh
test -s /usr/share/GeographicLib/geoids/egm96-5.pgm
if [[ "$ONBOARD_IMAGE_ROLE" == builder ]]; then
  for executable in gcc g++ make cmake ninja go rustc dpkg-deb fakeroot file; do command -v "$executable" >/dev/null; done
else
  # ROS packages may require CMake/headers transitively. Preserve declared dependencies.
  test ! -e /usr/local/go/bin/go
  test ! -d /usr/local/rustup
fi
