#!/usr/bin/env bash
# Two private experiment containers on the local FS150 baseline.
# Each container must have its own adapter socket. The other container's
# socket path must be absent. Absence is test -e, not stat: stat exits 1
# when the foreign path is missing and would hide a real isolation pass.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FS150_IMAGE="${FS150_IMAGE:-onboard-sim-fs150-focal-noetic:agent-0.1.0-2-local}"
FS150_ID="${FS150_ID:-sha256:c7ddf5e3088e3631b6e6f0560e6d7de9ec9770d55afedfa4fadd2a538bb96258}"
EVIDENCE="${TWO_EXPERIMENT_EVIDENCE:-${ROOT}/onboard-baseline/.local/two-experiment-proof.txt}"
mkdir -p "${ROOT}/onboard-baseline/.local"
exec > >(tee "$EVIDENCE") 2>&1

fail() {
  printf 'prove-two-experiments: %s\n' "$*" >&2
  exit 1
}

actual_id="$(docker image inspect "$FS150_IMAGE" --format '{{.Id}}')"
[[ "$actual_id" == "$FS150_ID" ]] || fail "FS150 image id is ${actual_id}, want ${FS150_ID}"
entrypoint="$(docker image inspect "$FS150_IMAGE" --format '{{json .Config.Entrypoint}}')"
[[ "$entrypoint" == '["/opt/xgc2/onboard-baseline/image-entrypoint.sh"]' ]] || fail "unexpected entrypoint ${entrypoint}"
echo "fs150_image=${FS150_IMAGE}"
echo "fs150_id=${actual_id}"
echo "entrypoint=/opt/xgc2/onboard-baseline/image-entrypoint.sh"

check_profile() {
  local image="$1" profile="$2"
  echo "== check ${profile} =="
  docker run --rm --network none "$image" \
    /opt/xgc2/onboard-baseline/onboard-baseline.sh check --profile "$profile"
  docker run --rm --network none "$image" bash -c '
    set -euo pipefail
    . /etc/os-release
    set +u
    # shellcheck disable=SC1090
    . "/opt/ros/${ROS_DISTRO}/setup.bash"
    set -u
    test "$(rosversion -d)" = "$ROS_DISTRO"
    test -x /usr/lib/xgc2/xgc-agent
    test -f /lib/systemd/system/xgc2-agent.service
    test -f /usr/lib/tmpfiles.d/xgc2-agent.conf
    grep -qx "XGC_AGENT_ID=agent-01" /etc/xgc2/agent.env
    grep -qx "agent_source=local-deb" /usr/share/xgc2-agent/install-source
    id xgc2 >/dev/null
    printf "os=%s ros=%s agent_user=xgc2\n" "$VERSION_CODENAME" "$ROS_DISTRO"
  '
}

check_profile onboard-sim-scout-bionic-melodic:agent-0.1.0-2-local scout-bionic-melodic
check_profile onboard-sim-scout-focal-noetic:agent-0.1.0-2-local scout-focal-noetic
check_profile onboard-sim-wheeltec-bionic-melodic:agent-0.1.0-2-local wheeltec-bionic-melodic
check_profile "$FS150_IMAGE" fs150-focal-noetic

echo "== fs150 sitl surface =="
docker run --rm --network none -e REQUIRE_SITL="${REQUIRE_SITL:-0}" "$FS150_IMAGE" bash -c "$(cat <<'EOS'
set -euo pipefail
dpkg-query -W -f '${Package} ${Version}\n' ros-noetic-mavros ros-noetic-mavros-msgs || true
if [[ -x /opt/ros/noetic/lib/mavros/mavros_node ]]; then echo mavros_node=present; else echo mavros_node=absent; fi
if [[ -s /usr/share/GeographicLib/geoids/egm96-5.pgm ]]; then echo geoid=present; else echo geoid=absent; fi
if dpkg-query -W ros-noetic-xgc2-gazebo-sim-fs150-sitl >/dev/null 2>&1; then
  dpkg-query -W -f 'sitl_package=${Package} ${Version}\n' ros-noetic-xgc2-gazebo-sim-fs150-sitl
else
  echo sitl_package=absent
fi
if dpkg-query -W ros-noetic-xgc2-px4-sitl-1-12 >/dev/null 2>&1; then
  dpkg-query -W -f 'px4_package=${Package} ${Version}\n' ros-noetic-xgc2-px4-sitl-1-12
else
  echo px4_package=absent
fi
if [[ -x /opt/ros/noetic/share/px4_sitl_1_12/runtime/bin/px4 ]]; then echo px4_binary=present; else echo px4_binary=absent; fi
if [[ -r /opt/ros/noetic/share/gazebo_sim_fs150_sitl/config/generated/fs150-sitl.params ]]; then echo fs150_params=present; else echo fs150_params=absent; fi
if [[ "${REQUIRE_SITL:-0}" == 1 ]]; then
  test "$(dpkg-query -W -f '${Version}' ros-noetic-xgc2-gazebo-sim-fs150-sitl)" = "1.1.0-23"
  test "$(dpkg-query -W -f '${Version}' ros-noetic-xgc2-px4-sitl-1-12)" = "1.12.3-27"
  test -r /opt/ros/noetic/share/px4_sitl_1_12/runtime/bin/px4
  test -x /opt/ros/noetic/share/px4_sitl_1_12/runtime/bin/px4
  test -r /opt/ros/noetic/share/gazebo_sim_fs150_sitl/config/generated/fs150-sitl.params
  echo sitl_required=present
fi
EOS
)"

names=(xgc2e-proof-a xgc2e-proof-b)
radios=(xgc2e-proof-a-radio xgc2e-proof-b-radio)
physics=(xgc2e-proof-a-physics xgc2e-proof-b-physics)
volumes=(xgc2e-proof-a-agent xgc2e-proof-a-managed xgc2e-proof-b-agent xgc2e-proof-b-managed)
cleanup() {
  docker rm -f "${names[@]}" >/dev/null 2>&1 || true
  docker volume rm "${volumes[@]}" >/dev/null 2>&1 || true
  docker network rm "${radios[@]}" "${physics[@]}" >/dev/null 2>&1 || true
}
cleanup
trap cleanup EXIT

docker network create --subnet 10.64.90.0/24 --gateway 10.64.90.251 xgc2e-proof-a-radio >/dev/null
docker network create --internal --subnet 10.68.90.0/24 --gateway 10.68.90.1 xgc2e-proof-a-physics >/dev/null
docker network create --subnet 10.64.91.0/24 --gateway 10.64.91.251 xgc2e-proof-b-radio >/dev/null
docker network create --internal --subnet 10.68.91.0/24 --gateway 10.68.91.1 xgc2e-proof-b-physics >/dev/null

start_one() {
  local name="$1" radio="$2" physnet="$3" rip="$4" pip="$5" agent="$6" core="$7" sock="$8"
  docker volume create "${name}-agent" >/dev/null
  docker volume create "${name}-managed" >/dev/null
  docker create --name "$name" --init \
    --network "$radio" --ip "$rip" \
    --mount "type=volume,source=${name}-agent,target=/var/lib/xgc2-agent" \
    --mount "type=volume,source=${name}-managed,target=/var/lib/xgc2-managed" \
    -e "XGC_AGENT_ID=${agent}" \
    -e "XGC_AGENT_DISPLAY_NAME=${name}" \
    -e XGC_AGENT_GRPC_ADDR=:9090 \
    -e "XGC_AGENT_ADVERTISED_ENDPOINT=${rip}:9090" \
    -e "XGC_CORE_ENDPOINT=${core}" \
    -e XGC_AGENT_DATA_DIR=/var/lib/xgc2-agent \
    -e XGC_AGENT_MANAGED_ROOT=/var/lib/xgc2-managed \
    -e "ROS_MASTER_URI=http://${rip%.*}.2:11311" \
    -e "GAZEBO_MASTER_URI=http://${pip%.*}.250:11345" \
    -e "ROS_IP=${rip}" \
    -e "XGC_ADAPTER_RUNTIME_UDS=${sock}" \
    "$FS150_IMAGE" >/dev/null
  docker network connect --ip "$pip" "$physnet" "$name"
  docker start "$name" >/dev/null
}

start_one xgc2e-proof-a xgc2e-proof-a-radio xgc2e-proof-a-physics 10.64.90.101 10.68.90.101 xgc2e-aaaaaaaaaaaaaaaaaaaa 10.64.90.251:9092 /run/xgc2/adapter/proof-a.sock
start_one xgc2e-proof-b xgc2e-proof-b-radio xgc2e-proof-b-physics 10.64.91.101 10.68.91.101 xgc2e-bbbbbbbbbbbbbbbbbbbb 10.64.91.251:9092 /run/xgc2/adapter/proof-b.sock

wait_sock() {
  local name="$1" sock="$2" i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if docker exec -u 0 "$name" test -S "$sock"; then
      return 0
    fi
    sleep 1
  done
  docker logs "$name" >&2 || true
  fail "socket ${sock} missing in ${name}"
}
wait_sock xgc2e-proof-a /run/xgc2/adapter/proof-a.sock
wait_sock xgc2e-proof-b /run/xgc2/adapter/proof-b.sock

assert_absent() {
  local name="$1" path="$2"
  if docker exec -u 0 "$name" test -e "$path"; then
    fail "foreign path ${path} is present in ${name}"
  fi
  echo "absent ${name} ${path}"
}
assert_absent xgc2e-proof-a /run/xgc2/adapter/proof-b.sock
assert_absent xgc2e-proof-b /run/xgc2/adapter/proof-a.sock

dump_env() {
  local name="$1"
  docker exec -u xgc2 "$name" python3 -c 'import os
want = {"XGC_AGENT_ID", "XGC_ADAPTER_RUNTIME_UDS", "ROS_IP", "ROS_MASTER_URI", "ROS_DISTRO", "USER"}
found = {}
for entry in os.listdir("/proc"):
    if not entry.isdigit():
        continue
    try:
        cmd = open("/proc/%s/cmdline" % entry, "rb").read()
        env = open("/proc/%s/environ" % entry, "rb").read()
    except OSError:
        continue
    if not cmd.startswith(b"/usr/lib/xgc2/xgc-agent"):
        continue
    for item in env.split(b"\0"):
        if not item or b"=" not in item:
            continue
        key, value = item.split(b"=", 1)
        key = key.decode()
        if key in want:
            found[key] = value.decode()
    break
else:
    raise SystemExit("agent process environ missing")
for key in sorted(want):
    print("%s=%s" % (key, found.get(key, "__unset__")))
'
}

for name in xgc2e-proof-a xgc2e-proof-b; do
  echo "== ${name} =="
  docker exec -u 0 "$name" ps -o user,pid,args -C xgc-agent
  docker exec -u 0 "$name" runuser -u xgc2 -- test -w /var/lib/xgc2-agent
  docker exec -u 0 "$name" runuser -u xgc2 -- test -w /var/lib/xgc2-managed
  echo writable=yes
  dump_env "$name"
  docker inspect "$name" --format '{{range $net, $cfg := .NetworkSettings.Networks}}{{$net}} {{$cfg.IPAddress}}{{"\n"}}{{end}}'
done

python3 - <<'PY'
import json, subprocess
raw = subprocess.check_output(["docker", "inspect", "xgc2e-proof-a", "xgc2e-proof-b"], text=True)
docs = json.loads(raw)
a, b = docs
a_nets = set(a["NetworkSettings"]["Networks"])
b_nets = set(b["NetworkSettings"]["Networks"])
if a_nets & b_nets:
    raise SystemExit("networks overlap %s" % (a_nets & b_nets))
a_vols = {m["Name"] for m in a["Mounts"]}
b_vols = {m["Name"] for m in b["Mounts"]}
if a_vols & b_vols:
    raise SystemExit("volumes overlap %s" % (a_vols & b_vols))
print("networks_disjoint=yes")
print("volumes_disjoint=yes")
PY

echo '--- tls ---'
echo | openssl s_client -connect 10.64.90.101:9090 -servername 10.64.90.101 2>/dev/null | awk '/Protocol|Cipher|Verify return code/{print}'
echo | openssl s_client -connect 10.64.91.101:9090 -servername 10.64.91.101 2>/dev/null | awk '/Protocol|Cipher|Verify return code/{print}'

echo '--- stop A, B remains ---'
docker stop xgc2e-proof-a >/dev/null
docker exec -u 0 xgc2e-proof-b test -S /run/xgc2/adapter/proof-b.sock
assert_absent xgc2e-proof-b /run/xgc2/adapter/proof-a.sock
docker exec -u 0 xgc2e-proof-b ps -o user,args -C xgc-agent
echo 'B remains after A stopped'
echo PROOF_OK
