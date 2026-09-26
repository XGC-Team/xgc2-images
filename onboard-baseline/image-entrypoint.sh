#!/usr/bin/env bash
# Container path: no systemd. Caller environment wins over /etc/xgc2/agent.env.
# The package default catalog is /usr/share/xgc2-agent/process-definitions.
# A robot catalog passed in XGC_PROCESS_DEFINITION_PLUGINS replaces it.
# This does not claim the systemd unit is enabled, and it does not disable ROS.
set -euo pipefail
if [[ $# -gt 0 ]]; then
  exec "$@"
fi
if [[ -d /run/systemd/system ]]; then
  printf 'onboard-baseline: systemd is running; use systemctl, not this entrypoint\n' >&2
  exit 1
fi

# Same keys as agentprofile.ConfigFromEnvironment, CatalogConfigFromEnvironment,
# and AdapterRuntimePathsFromEnvironment. Caller values replace the package
# conffile, including a robot catalog in XGC_PROCESS_DEFINITION_PLUGINS.
# The package default remains /usr/share/xgc2-agent/process-definitions.
# This list does not point at Core's /usr/share/xgc2 catalog or turn ROS off.
declare -A incoming=()
preserve_key() {
  [[ -v $1 ]] || return 0
  incoming[$1]="${!1}"
}
for key in \
  XGC_AGENT_ID \
  XGC_AGENT_DISPLAY_NAME \
  XGC_AGENT_GRPC_ADDR \
  XGC_CORE_ENDPOINT \
  XGC_AGENT_ADVERTISED_ENDPOINT \
  XGC_AGENT_DATA_DIR \
  XGC_AGENT_MANAGED_ROOT \
  XGC_AGENT_DOWNLOAD_HOSTS \
  XGC_AGENT_IDENTITY_KEY \
  XGC_AGENT_ACCESS_TOKEN_FILE \
  XGC_AGENT_CORE_PIN_PATH \
  XGC_USER_FILES_DIR \
  XGC_PROCESS_DEFINITION_PLUGINS \
  XGC_PROCESS_CATALOG_ROOT \
  XGC_ADAPTER_DEFINITION_PATHS \
  XGC_ADAPTER_RUNTIME_UDS \
  XGC_ADAPTER_RUNTIME_DIR \
  XGC_ROBOT_ADAPTER_PROFILE_PATHS \
  XGC_GAZEBO_SCENE_PLUGIN_PATH \
  XGC_GAZEBO_VRPN_PLUGIN_PATH \
  XGC_GAZEBO_VRPN_CONFIG_PATH \
  ROS_MASTER_URI \
  ROS_IP \
  ROS_HOSTNAME \
  ROS_HOME \
  ROS_LOG_DIR
do
  preserve_key "$key"
done
while IFS= read -r key; do
  [[ "$key" == XGC_ADAPTER_* ]] || continue
  preserve_key "$key"
done < <(compgen -e)

if [[ -f /etc/xgc2/agent.env ]]; then
  set -a
  # shellcheck disable=SC1091
  . /etc/xgc2/agent.env
  set +a
fi
for key in "${!incoming[@]}"; do
  export "$key=${incoming[$key]}"
done
if [[ -n "${ROS_DISTRO:-}" && -f "/opt/ros/${ROS_DISTRO}/setup.bash" ]]; then
  # shellcheck disable=SC1090
  source "/opt/ros/${ROS_DISTRO}/setup.bash"
fi
for key in "${!incoming[@]}"; do
  export "$key=${incoming[$key]}"
done
# A root shell's ROS_HOME is not writable by xgc2. Caller ROS_HOME wins;
# otherwise logs go to the deb user's home.
if [[ ! -v 'incoming[ROS_HOME]' ]]; then
  export ROS_HOME=/home/xgc2/.ros
fi
if [[ ! -v 'incoming[ROS_LOG_DIR]' ]]; then
  export ROS_LOG_DIR="${ROS_HOME}/log"
fi
data_dir="${XGC_AGENT_DATA_DIR:-/var/lib/xgc2-agent}"
managed_root="${XGC_AGENT_MANAGED_ROOT:-/var/lib/xgc2-managed}"
install -d -o xgc2 -g xgc2 -m 0750 -- "$data_dir" "$managed_root"
tmpfiles=""
for candidate in /usr/lib/tmpfiles.d/xgc2-agent.conf /lib/tmpfiles.d/xgc2-agent.conf; do
  if [[ -f "$candidate" ]]; then
    tmpfiles="$candidate"
    break
  fi
done
if [[ -n "$tmpfiles" ]]; then
  systemd-tmpfiles --create "$tmpfiles"
fi
id xgc2 >/dev/null
if [[ "$ROS_HOME" == /home/xgc2/.ros ]]; then
  install -d -o xgc2 -g xgc2 -m 0750 -- "$ROS_HOME" "$ROS_LOG_DIR"
fi
cd "$data_dir"
runuser -u xgc2 -- test -w "$data_dir"
runuser -u xgc2 -- test -w "$managed_root"
runuser -u xgc2 -- test -w "$ROS_HOME"
runuser -u xgc2 -- test -w "$ROS_LOG_DIR"
export HOME=/home/xgc2
export USER=xgc2
export LOGNAME=xgc2
exec runuser --preserve-environment -u xgc2 -- /usr/lib/xgc2/xgc-agent
