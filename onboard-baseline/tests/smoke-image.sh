#!/usr/bin/env bash
# Explicit, disposable-container acceptance only. Never run this payload on a robot.
# No host mounts, published ports, hardware devices, Agent, or external network.
set -euo pipefail
if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: bash smoke-image.sh PROFILE LOCAL_IMAGE [linux/amd64|linux/arm64]" >&2
  exit 2
fi
profile="$1"
image="$2"
platform="${3:-linux/amd64}"
case "$platform" in linux/amd64|linux/arm64) ;; *) echo 'unsupported test platform' >&2; exit 2 ;; esac
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$root/baselines.json" "$profile" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    profiles = json.load(f)["profiles"]
if sys.argv[2] not in profiles:
    raise SystemExit("unknown baseline profile")
PY
if ! command -v docker >/dev/null 2>&1; then
  echo 'NOT RUN: Docker is required for real image acceptance' >&2
  exit 77
fi
# Require an already-built local image, not an implicit pull or release.
actual="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")"
[[ "$actual" == "$platform" ]] || { echo "image platform $actual != $platform" >&2; exit 1; }
docker run --rm -i --pull=never --network none --platform "$platform" \
  --user 0:0 --entrypoint /bin/bash -e "TEST_PROFILE=$profile" "$image" -s <<'CONTAINER'
set -euo pipefail
[[ "$TEST_PROFILE" == "$ONBOARD_BASELINE_PROFILE" ]]
[[ "$ONBOARD_BASELINE_USER" != root && "$ONBOARD_BASELINE_USER" != xgc2 ]]
baseline=/opt/xgc2/onboard-baseline/onboard-baseline.sh
# Deliberate test fixture in a disposable container; never a field configuration.
mkdir -p /etc/xgc2
printf 'XGC_AGENT_ID=w06-configuration-sentinel\n' > /etc/xgc2/agent.env
before="$(sha256sum /etc/xgc2/agent.env "/home/$ONBOARD_BASELINE_USER/.bashrc")"
packages_before="$(dpkg-query -W -f='${Package}\t${Status}\t${Version}\n')"
guard="$(mktemp -d)"
for cmd in apt apt-get geographiclib-get-geoids; do
  printf '#!/bin/sh\necho "unexpected maintenance command: %s" >&2\nexit 88\n' "$cmd" > "$guard/$cmd"
  chmod 0755 "$guard/$cmd"
done
# An already-applied image must not invoke apt or re-download the geoid.
PATH="$guard:$PATH" bash "$baseline" apply --profile "$TEST_PROFILE"
PATH="$guard:$PATH" bash "$baseline" apply --profile "$TEST_PROFILE"
[[ "$before" == "$(sha256sum /etc/xgc2/agent.env "/home/$ONBOARD_BASELINE_USER/.bashrc")" ]]
[[ "$packages_before" == "$(dpkg-query -W -f='${Package}\t${Status}\t${Version}\n')" ]]
rm -rf -- "$guard"
runuser -u "$ONBOARD_BASELINE_USER" -- "$baseline" check --profile "$TEST_PROFILE"
# Exercise real ROS messaging and, for FS150, MAVROS initialization/state output.
# Loopback is the only interface in --network none; no FCU or motion is requested.
runuser -u "$ONBOARD_BASELINE_USER" -- /bin/bash -s <<'ROBOT_USER'
set -eo pipefail
unset ROS_HOSTNAME ROS_PACKAGE_PATH CMAKE_PREFIX_PATH PYTHONPATH PYTHONHOME LD_LIBRARY_PATH
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
source "/opt/ros/$ROS_DISTRO/setup.bash"
export ROS_MASTER_URI=http://127.0.0.1:11311 ROS_IP=127.0.0.1
export ROS_HOME
ROS_HOME="$(mktemp -d)"
export ROS_LOG_DIR="$ROS_HOME/log" PYTHONDONTWRITEBYTECODE=1
master_pid='' mavros_pid=''
cleanup() {
  result=$?
  trap - EXIT
  [[ -z "$mavros_pid" ]] || kill "$mavros_pid" 2>/dev/null || true
  [[ -z "$master_pid" ]] || kill "$master_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  if [[ "$result" != 0 ]]; then
    cat "$ROS_HOME"/*.log 2>/dev/null || true
  fi
  rm -rf -- "$ROS_HOME"
  exit "$result"
}
trap cleanup EXIT
roscore > "$ROS_HOME/master.log" 2>&1 & master_pid=$!
ros_python=python3
[[ "$ROS_DISTRO" != melodic ]] || ros_python=python2
"$ros_python" - <<'PY'
import os, time
try:
    from xmlrpc.client import ServerProxy
except ImportError:
    from xmlrpclib import ServerProxy
master = ServerProxy(os.environ["ROS_MASTER_URI"])
for attempt in range(100):
    try:
        if master.getPid("/w06_smoke")[0] == 1:
            break
    except Exception:
        pass
    time.sleep(0.1)
else:
    raise SystemExit("ROS master did not become ready")
import threading, rospy
from std_msgs.msg import String
rospy.init_node("w06_smoke", anonymous=True)
received = threading.Event()
def callback(message):
    if message.data == "w06-local-roundtrip":
        received.set()
subscriber = rospy.Subscriber("/w06_smoke/roundtrip", String, callback, queue_size=1)
publisher = rospy.Publisher("/w06_smoke/roundtrip", String, queue_size=1, latch=True)
publisher.publish(String(data="w06-local-roundtrip"))
if not received.wait(10):
    raise SystemExit("ROS publish/subscribe roundtrip failed")
print("ROS publish/subscribe roundtrip passed")
PY
if [[ "$ONBOARD_BASELINE_PROFILE" == fs150-focal-noetic ]]; then
  roslaunch mavros px4.launch \
    fcu_url:='udp://127.0.0.1:14540@127.0.0.1:14557' gcs_url:='' \
    > "$ROS_HOME/mavros.log" 2>&1 & mavros_pid=$!
  "$ros_python" - <<'PY'
import rospy
from mavros_msgs.msg import State
rospy.init_node("w06_mavros_observer", anonymous=True)
rospy.wait_for_service("/mavros/set_mode", timeout=30)
state = rospy.wait_for_message("/mavros/state", State, timeout=15)
if state.connected:
    raise SystemExit("unexpected FCU connection in isolated smoke test")
print("MAVROS service registration and State receive passed; no FCU connected")
PY
fi
ROBOT_USER
printf 'W06 disposable image smoke passed: %s\n' "$TEST_PROFILE"
CONTAINER
