#!/usr/bin/env bash
# Container path: no systemd. Caller environment wins over /etc/xgc2/agent.env.
# The image starts only the Agent daemon. A saved autostart workflow may start
# a chassis later; this entrypoint does not start drivers, algorithms, or a ROS master.
set -euo pipefail
if [[ $# -gt 0 ]]; then
  exec "$@"
fi
if [[ -d /run/systemd/system ]]; then
  printf 'onboard-baseline: systemd is running; use systemctl, not this entrypoint\n' >&2
  exit 1
fi
# Installation and runtime directory preparation need root; the Agent itself
# must run through runuser below, as the image's existing robot account.
if (( EUID != 0 )); then
  printf 'onboard-baseline: container entrypoint requires root to prepare the robot account\n' >&2
  exit 1
fi
agent_user="${ONBOARD_BASELINE_USER:?Set the existing robot user}"
agent_group="$(id -gn "$agent_user")"
agent_home="$(getent passwd "$agent_user" | cut -d: -f6)"
# The live package is installed while the image is built. A copied deb is not
# a stand-in, and this process does not install or start anything else.
if [[ ! -x /usr/lib/xgc2/xgc-agent ]]; then
  printf 'onboard-baseline: xgc2-agent is not installed\n' >&2
  exit 1
fi

# Keys read by the current Agent, plus the ROS environment a later workflow
# can inherit. Caller values replace the package conffile. Old catalog,
# adapter, and simulator paths are not part of daemon startup.
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
  XGC_AGENT_IDENTITY_KEY \
  XGC_AGENT_ACCESS_TOKEN_FILE \
  XGC_AGENT_CORE_PIN_PATH \
  ROS_MASTER_URI \
  ROS_IP \
  ROS_HOSTNAME \
  ROS_HOME \
  ROS_LOG_DIR
do
  preserve_key "$key"
done

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
  # ROS setup scripts read optional environment variables without defaults.
  set +u
  # shellcheck disable=SC1090
  source "/opt/ros/${ROS_DISTRO}/setup.bash"
  set -u
fi
for key in "${!incoming[@]}"; do
  export "$key=${incoming[$key]}"
done
# Do not boot the package placeholder or let an explicitly empty caller value
# silently choose Agent defaults. A configured conffile is still supported.
for key in XGC_AGENT_ID XGC_CORE_ENDPOINT XGC_AGENT_ADVERTISED_ENDPOINT; do
  if [[ -z "${!key:-}" ]]; then
    printf 'onboard-baseline: %s is required for container Agent startup\n' "$key" >&2
    exit 1
  fi
done
if [[ "$XGC_AGENT_ID" == agent-01 ]]; then
  printf 'onboard-baseline: agent-01 is a package placeholder, not a container identity\n' >&2
  exit 1
fi

# Caller ROS_HOME wins; otherwise ROS logs use the robot operator home.
if [[ ! -v 'incoming[ROS_HOME]' ]]; then
  export ROS_HOME="$agent_home/.ros"
fi
if [[ ! -v 'incoming[ROS_LOG_DIR]' ]]; then
  export ROS_LOG_DIR="${ROS_HOME}/log"
fi
data_dir="${XGC_AGENT_DATA_DIR:-/var/lib/xgc2-agent}"
managed_root="${XGC_AGENT_MANAGED_ROOT:-/var/lib/xgc2-managed}"
# An empty Docker volume arrives root-owned. Initialize that directory only;
# never repair permissions or ownership on an existing nonempty Agent store.
if [[ ! -e "$data_dir" ]]; then
  install -d -o "$agent_user" -g "$agent_group" -m 0700 -- "$data_dir"
elif [[ -d "$data_dir" && ! -L "$data_dir" ]]; then
  data_entry="$(find "$data_dir" -mindepth 1 -maxdepth 1 -print -quit)"
  if [[ -z "$data_entry" ]]; then
    install -d -o "$agent_user" -g "$agent_group" -m 0700 -- "$data_dir"
  fi
fi
install -d -o "$agent_user" -g "$agent_group" -m 0750 -- "$managed_root" /run/xgc2-agent /run/xgc2/adapter
# This permission applies only to operator-managed experiment containers.
install -d -m 0755 /etc/sudoers.d
printf '%s ALL=(root) NOPASSWD: ALL\n' "$agent_user" > /etc/sudoers.d/robot-operator
chmod 0440 /etc/sudoers.d/robot-operator
if [[ "$ROS_HOME" == "$agent_home/.ros" ]]; then
  install -d -o "$agent_user" -g "$agent_group" -m 0750 -- "$ROS_HOME" "$ROS_LOG_DIR"
fi
# A writable but non-searchable directory is not usable by Files/Terminal.
# Check as the real account, including HOME, without recursively reowning data
# or silently creating caller-supplied ROS directories.
runuser -u "$agent_user" -- /bin/bash -c '
  for directory; do
    if [[ ! -d "$directory" || ! -r "$directory" || ! -w "$directory" || ! -x "$directory" ]]; then
      printf "onboard-baseline: directory not usable by %s: %s\n" "$USER" "$directory" >&2
      exit 1
    fi
  done
' onboard-baseline "$agent_home" "$data_dir" "$managed_root" "$ROS_HOME" "$ROS_LOG_DIR"
# Drop a stale catalog or simulator path. The daemon does not launch it;
# a saved workflow supplies its own command when Core is offline.
# Command substitution stays in this shell. Process substitution needs /dev/fd,
# which the isolated chroot does not provide.
for key in $(compgen -e); do
  case "$key" in
    XGC_PROCESS_DEFINITION_PLUGINS|XGC_PROCESS_CATALOG_ROOT|XGC_USER_FILES_DIR|XGC_AGENT_DOWNLOAD_HOSTS|GAZEBO_MASTER_URI)
      unset "$key" ;;
    XGC_ADAPTER_*|XGC_GAZEBO_*|XGC_ROBOT_ADAPTER_*)
      unset "$key" ;;
  esac
done
cd "$data_dir"
export HOME="$agent_home"
export USER="$agent_user"
export LOGNAME="$agent_user"
exec runuser --preserve-environment -u "$agent_user" -- /usr/lib/xgc2/xgc-agent
