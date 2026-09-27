#!/usr/bin/env bash
# Explicit, disposable image test. Never use a host network, device or robot.
# Requires a locally built image. This does not install Docker or pull images.
set -euo pipefail
[[ $# == 1 ]] || { echo "usage: bash onboard-baseline/tests/smoke-image.sh LOCAL_IMAGE" >&2; exit 2; }
command -v docker >/dev/null || { echo 'NOT RUN: Docker is unavailable' >&2; exit 77; }
docker info >/dev/null 2>&1 || { echo 'NOT RUN: Docker daemon is unavailable' >&2; exit 77; }
image="$1"
image_env="$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image")"
profile="$(sed -n 's/^ONBOARD_BASELINE_PROFILE=//p' <<<"$image_env")"
robot_user="$(sed -n 's/^ONBOARD_BASELINE_USER=//p' <<<"$image_env")"
platform="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")"
case "$profile" in
  fs150-focal-noetic|scout-bionic-melodic|scout-focal-noetic|wheeltec-bionic-melodic) ;;
  *) echo "not an onboard baseline image: $profile" >&2; exit 2 ;;
esac
[[ -n "$robot_user" && "$robot_user" != root && "$robot_user" != 0 ]] || { echo 'missing/non-robot image user' >&2; exit 2; }
options=(--rm --pull=never --platform "$platform" --network none --read-only
  --tmpfs /tmp:rw,nosuid,nodev --cap-drop ALL --security-opt no-new-privileges
  --entrypoint /bin/bash)
echo "image=$image platform=$platform profile=$profile user=$robot_user"
docker image inspect --format 'image_id={{.Id}}' "$image"

# All package state is real. Sentinels make any unexpected apt/download fail;
# the read-only root and network=none also prevent configuration/network writes.
docker run "${options[@]}" --user root -i "$image" -s -- "$profile" <<'IDEMPOTENCE'
set -euo pipefail
profile="$1"
work="$(mktemp -d)"
mkdir "$work/bin"
printf '#!/bin/sh\necho "unexpected install/download: $0" >&2\nexit 97\n' >"$work/bin/apt-get"
chmod +x "$work/bin/apt-get"
ln -s apt-get "$work/bin/geographiclib-get-geoids"
export PATH="$work/bin:$PATH"
script=/opt/xgc2/onboard-baseline/onboard-baseline.sh
"$script" snapshot --profile "$profile" >"$work/before"
"$script" apply --profile "$profile"
"$script" apply --profile "$profile"
"$script" snapshot --profile "$profile" >"$work/after"
"$script" manualdiff --before "$work/before" --after "$work/after"
cmp "$work/before" "$work/after"
echo 'image repeated apply: no apt/download or snapshot change'
IDEMPOTENCE

# An ordinary robot user, private loopback, no device mounts and no capabilities.
# The FS150 test sends only an unarmed synthetic heartbeat to a local MAVROS.
docker run "${options[@]}" --user "$robot_user" -i "$image" -s -- "$profile" <<'RUNTIME'
set -eo pipefail
profile="$1"
[[ "$(id -u)" != 0 ]]
/opt/xgc2/onboard-baseline/onboard-baseline.sh check --profile "$profile"
export HOME="$(mktemp -d)"
export ROS_HOME="$HOME/.ros" ROS_LOG_DIR="$HOME/.ros/log"
export ROS_MASTER_URI=http://127.0.0.1:11311 ROS_HOSTNAME=127.0.0.1
unset ROS_IP
source "/opt/ros/$ROS_DISTRO/setup.bash"
core_pid=""
mavros_pid=""
cleanup() {
  rc=$?
  trap - EXIT
  set +e
  [[ -z "$mavros_pid" ]] || kill "$mavros_pid" 2>/dev/null
  [[ -z "$core_pid" ]] || kill "$core_pid" 2>/dev/null
  [[ -z "$mavros_pid" ]] || wait "$mavros_pid" 2>/dev/null
  [[ -z "$core_pid" ]] || wait "$core_pid" 2>/dev/null
  if [[ "$rc" != 0 ]]; then
    cat "$HOME/roscore.log" "$HOME/mavros.log" 2>/dev/null
  fi
  exit "$rc"
}
trap cleanup EXIT
roscore >"$HOME/roscore.log" 2>&1 &
core_pid=$!
timeout 30 bash -c 'until rosparam list >/dev/null 2>&1; do sleep 0.2; done'
if [[ "$profile" == fs150-focal-noetic ]]; then
  roslaunch mavros px4.launch fcu_url:=udp://127.0.0.1:14540@127.0.0.1:14557 gcs_url:= >"$HOME/mavros.log" 2>&1 &
  mavros_pid=$!
fi
python=python3
[[ "$ROS_DISTRO" != melodic ]] || python=python
timeout 50 "$python" - "$profile" <<'PY'
from __future__ import print_function
import socket
import struct
import sys
import threading
import time
import rospy
from std_msgs.msg import String

rospy.init_node('w06_runtime_probe', disable_signals=True)
received = threading.Event()
subscriber = rospy.Subscriber('/w06/probe', String,
                              lambda msg: received.set() if msg.data == 'w06' else None)
publisher = rospy.Publisher('/w06/probe', String, queue_size=1, latch=True)
publisher.publish(String(data='w06'))
if not received.wait(10):
    raise RuntimeError('ROS message round-trip failed')
print('ROS message round-trip: w06')

if sys.argv[1] == 'fs150-focal-noetic':
    from mavros_msgs.msg import State
    connected = threading.Event()
    def observe(msg):
        if msg.connected and not msg.armed and msg.system_status == 3:
            connected.set()
    state_subscriber = rospy.Subscriber('/mavros/state', State, observe)
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(('127.0.0.1', 14557))
    # MAVLink v1 HEARTBEAT: quadrotor/PX4, unarmed, standby; CRC_EXTRA=50.
    # This fixture tests decoding only. There is no PX4, actuator or real FCU.
    payload = struct.pack('<IBBBBB', 0, 2, 12, 0, 3, 3)
    deadline, sequence = time.time() + 25, 0
    while time.time() < deadline and not connected.is_set():
        header = struct.pack('<BBBBBB', 0xfe, len(payload), sequence, 1, 1, 0)
        crc = 0xffff
        for value in bytearray(header[1:] + payload + b'\x32'):
            tmp = value ^ (crc & 0xff)
            tmp ^= (tmp << 4) & 0xff
            crc = ((crc >> 8) ^ (tmp << 8) ^ (tmp << 3) ^ (tmp >> 4)) & 0xffff
        udp.sendto(header + payload + struct.pack('<H', crc), ('127.0.0.1', 14540))
        sequence = (sequence + 1) % 256
        connected.wait(0.2)
    udp.close()
    if not connected.is_set():
        raise RuntimeError('MAVROS did not decode the loopback unarmed heartbeat')
    print('MAVROS heartbeat -> ROS State: connected=true armed=false system_status=3')
rospy.signal_shutdown('W06 image smoke complete')
PY
RUNTIME
