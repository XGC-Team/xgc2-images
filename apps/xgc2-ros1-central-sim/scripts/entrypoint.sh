#!/usr/bin/env bash
set -euo pipefail

# No command: stay up as the same Agent the onboard images run. An explicit
# command (the compose shell) keeps the interactive path below.
if [[ $# -eq 0 ]]; then
  exec /opt/xgc2/onboard-baseline/image-entrypoint.sh
fi

export ROS_MASTER_URI="${ROS_MASTER_URI:-http://127.0.0.1:11311}"
source /opt/ros/noetic/setup.bash
export DISABLE_ROS1_EOL_WARNINGS="${DISABLE_ROS1_EOL_WARNINGS:-1}"

if [[ -n "${ROS_IP:-}" ]]; then
  export ROS_IP
fi
if [[ -n "${ROS_HOSTNAME:-}" ]]; then
  export ROS_HOSTNAME
fi

if [[ "$(id -u)" != "0" ]]; then
  exec "$@"
fi

user="${XGC_USER:-xgc}"
uid="${USER_UID:-1000}"
gid="${USER_GID:-1000}"

if ! getent group "${gid}" >/dev/null; then
  groupadd --gid "${gid}" "${user}"
fi

existing_user="$(getent passwd "${uid}" | cut -d: -f1 || true)"
if [[ -n "${existing_user}" ]]; then
  user="${existing_user}"
elif ! id "${user}" >/dev/null 2>&1; then
  useradd --create-home --uid "${uid}" --gid "${gid}" --shell /bin/bash "${user}"
else
  usermod --uid "${uid}" --gid "${gid}" "${user}"
fi

for group in dialout video render; do
  if getent group "${group}" >/dev/null; then
    usermod --append --groups "${group}" "${user}"
  fi
done

home="$(getent passwd "${user}" | cut -d: -f6)"
install -d -o "${uid}" -g "${gid}" -m 0755 \
  "${home}" \
  /home/xgc_ws \
  "${XGC2_SIM_LOG_DIR:-/var/log/xgc2-sim}" \
  "${XGC_PROCESS_STATE_DIR:-/run/xgc/processes}" \
  "${XGC_PROCESS_LOG_DIR:-/var/log/xgc/processes}" \
  /var/lib/xgc2/qgroundcontrol/config \
  /var/lib/xgc2/qgroundcontrol/cache
chown -R "${uid}:${gid}" \
  "${XGC2_SIM_LOG_DIR:-/var/log/xgc2-sim}" \
  "${XGC_PROCESS_STATE_DIR:-/run/xgc/processes}" \
  "${XGC_PROCESS_LOG_DIR:-/var/log/xgc/processes}" \
  /var/lib/xgc2/qgroundcontrol

export HOME="${home}"
export USER="${user}"
export LOGNAME="${user}"

exec gosu "${user}" "$@"
