#!/usr/bin/env bash
# Real PID-1 regression in a disposable container; no host mounts or network.
set -euo pipefail
[[ $# == 1 ]] || { echo 'usage: smoke-systemd-chrony.sh IMAGE' >&2; exit 2; }
image="$1"
name="xgc2-chrony-systemd-test-$$"
cleanup() { docker stop --timeout 10 "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
# Docker uses a private cgroup namespace. SYS_ADMIN is needed only to remount
# that container's cgroup view; SYS_TIME is explicitly absent. No --privileged,
# host filesystem mount, host network, or host PID namespace is used.
docker run -d --rm --name "$name" --network none --cgroupns private \
  --cap-drop SYS_TIME --cap-add SYS_ADMIN --security-opt seccomp=unconfined \
  --security-opt apparmor=unconfined --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
  --stop-signal SIGRTMIN+3 --entrypoint bash "$image" \
  -c 'set -e; mount -o remount,rw /sys/fs/cgroup; exec /sbin/init' >/dev/null
docker exec -i "$name" bash -se <<'CHECK'
for ((i=0; i<40; i++)); do
  state="$(systemctl show multi-user.target -p ActiveState --value 2>/dev/null || true)"
  [[ "$state" != active ]] || break
  sleep 1
done
[[ "${state:-}" == active ]] || { echo 'systemd multi-user target did not start' >&2; exit 1; }
python3 - <<'PY'
from pathlib import Path
status = Path('/proc/1/status').read_text()
caps = int(next(row.split()[1] for row in status.splitlines() if row.startswith('CapEff:')), 16)
assert not caps & (1 << 25), 'CAP_SYS_TIME must be absent'
print('PID 1 has no CAP_SYS_TIME')
PY
for unit in chrony.service chronyd.service; do
  [[ "$(systemctl show "$unit" -p LoadState --value)" == masked ]]
  [[ "$(systemctl show "$unit" -p ActiveState --value)" == inactive ]]
  [[ "$(systemctl show "$unit" -p UnitFileState --value)" == masked ]]
  if systemctl start "$unit" >/dev/null 2>&1; then
    echo "masked unit unexpectedly started: $unit" >&2; exit 1
  fi
done
if pgrep -x chronyd >/dev/null; then echo 'chronyd is running' >&2; exit 1; fi
[[ "$(dpkg-query -W -f='${Status}' chrony)" == 'install ok installed' ]]
test -x /usr/bin/chronyc
test -x /usr/sbin/chronyd
/opt/xgc2/onboard-baseline/check-image.sh
printf 'PASS: real systemd boot, chrony and chronyd masked/inactive, no chronyd, tools retained\n'
CHECK
