#!/usr/bin/env bash
set -euo pipefail
/opt/xgc2/onboard-baseline/check-simulation.sh
test -s /usr/share/GeographicLib/geoids/egm96-5.pgm
# Units are masked in the image, not on the host. Keep the chrony tools.
test -x /usr/bin/chronyc
test -x /usr/sbin/chronyd
for unit in chrony.service chronyd.service; do
  path="/etc/systemd/system/$unit"
  [[ -L "$path" && "$(readlink "$path")" == /dev/null ]] || {
    echo "Chrony unit is not masked: $unit" >&2; exit 1;
  }
done
if [[ "$(id -u)" == 0 ]]; then
  runuser -u "$ONBOARD_BASELINE_USER" -- /opt/xgc2/onboard-baseline/check-network-databases.sh
else
  /opt/xgc2/onboard-baseline/check-network-databases.sh
fi
set +u # ROS setup reads optional variables.
source /opt/ros/noetic/setup.bash
set -u
python3 -B -c "import rospy, zenoh"
# The SDK package owns the code-generation entry; this is a runtime consumer
# check only, never a second install path.
set +u
source /opt/xgc2/acados/setup.bash
set -u
test "${XGC2_ACADOS_PYTHON:-}" = "/usr/bin/python3"
test "$(dpkg-query -W -f='${Version}' xgc2-acados)" = "0.6.0-1~focal"
"${XGC2_ACADOS_PYTHON}" -B - <<'PY'
import pathlib

import acados_template
import casadi

root = pathlib.Path('/opt/xgc2/acados').resolve()
assert casadi.__version__ == '3.7.2'
assert root in pathlib.Path(acados_template.__file__).resolve().parents
assert (root / 'python').resolve() in pathlib.Path(casadi.__file__).resolve().parents
PY
python3 -B /opt/xgc2/onboard-baseline/check-mavros-vision-plugin.py
vision_deps="$(ldd /opt/ros/noetic/lib/libmavros_extras.so)"
if grep -q 'not found' <<<"$vision_deps"; then
  printf '%s\n' "$vision_deps" >&2
  exit 1
fi
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
