#!/usr/bin/env bash
# Idempotent base environment for onboard simulation images and real machines.
# check is read-only. apply installs only the profile package list and does not
# remove user packages, start a chassis, or start an experiment.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASELINES="${ROOT}/baselines.json"
OS_RELEASE="${ONBOARD_BASELINE_OS_RELEASE:-/etc/os-release}"
XGC2_APT_FINGERPRINT="2A8E11B36F56D307ADF626D85E5FDC30979EA43F"

usage() {
  echo "usage: onboard-baseline.sh check|apply|snapshot --profile <fs150-focal-noetic|scout-bionic-melodic|scout-focal-noetic|wheeltec-bionic-melodic>" >&2
  echo "       onboard-baseline.sh install-sitl --profile fs150-focal-noetic" >&2
  echo "       onboard-baseline.sh install-agent [--user EXISTING_USER] [--profile <fs150-focal-noetic|scout-bionic-melodic|scout-focal-noetic|wheeltec-bionic-melodic>]" >&2
  echo "       onboard-baseline.sh manualdiff --before SNAPSHOT --after SNAPSHOT" >&2
  exit 2
}

fail() {
  printf 'onboard-baseline: %s\n' "$1" >&2
  exit "${2:-1}"
}

mode="${1:-}"
shift || usage
if [[ "$mode" == "manualdiff" ]]; then
  before=""
  after=""
  while (($#)); do
    case "$1" in
      --before) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || usage; before="$2"; shift 2 ;;
      --after) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || usage; after="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ -f "$before" && -f "$after" ]] || usage
  set +e
  python3 - "$before" "$after" <<'PY'
import sys
def manual(path):
    rows = []
    for line in open(path, encoding="utf-8"):
        if line.startswith("manual\t"):
            rows.append(line.rstrip("\n"))
    return rows
before, after = sys.argv[1:]
old, new = manual(before), manual(after)
removed = sorted(set(old) - set(new))
added = sorted(set(new) - set(old))
for line in removed:
    print("- " + line)
for line in added:
    print("+ " + line)
print("manualdiff removed=%d added=%d" % (len(removed), len(added)))
sys.exit(1 if removed or added else 0)
PY
  rc=$?
  set -e
  exit "$rc"
fi
profile=""
agent_user="${ONBOARD_BASELINE_USER:-${SUDO_USER:-}}"
while (($#)); do
  case "$1" in
    --profile) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || usage; profile="$2"; shift 2 ;;
    --user) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || usage; agent_user="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$mode" == "check" || "$mode" == "apply" || "$mode" == "snapshot" || "$mode" == "install-agent" || "$mode" == "install-sitl" ]] || usage
if [[ "$mode" != "install-agent" && -z "$profile" ]]; then
  usage
fi
[[ -f "$BASELINES" ]] || usage

# Melodic images may initially have only Python 2. The JSON-only bootstrap
# can use it for explicit apply; the profile then installs Python 3. Read-only
# operations and Agent installation continue to require Python 3.
profile_python=python3
if ! command -v "$profile_python" >/dev/null 2>&1; then
  if [[ "$mode" == "apply" ]] && command -v python2 >/dev/null 2>&1; then
    profile_python=python2
  else
    fail "python3 is required (apply can bootstrap using python2)" 2
  fi
fi

if [[ -n "$profile" ]]; then
  # Capture the producer's status before eval: eval of empty output returns 0.
  profile_vars="$("$profile_python" - "$BASELINES" "$profile" <<'PY'
import io, json, re, sys
try:
    from shlex import quote
except ImportError:
    from pipes import quote
with io.open(sys.argv[1], encoding="utf-8") as source:
    doc = json.load(source)
profile = doc["profiles"][sys.argv[2]]
packages = profile["packages"]
architectures = doc["architectures"]
if not isinstance(packages, list) or not packages:
    raise SystemExit("profile has no package list")
if any(not re.match(r"^[a-z0-9][a-z0-9+.-]*$", item) for item in packages):
    raise SystemExit("invalid package name")
if not isinstance(architectures, list) or not architectures:
    raise SystemExit("baseline has no architecture list")
print("ubuntu_codename=" + quote(profile["ubuntuCodename"]))
print("ubuntu_version_id=" + quote(profile["ubuntuVersionId"]))
print("ros_distro=" + quote(profile["rosDistro"]))
print("agent_package=" + quote(doc["agentPackage"]))
print("packages=(" + " ".join(quote(item) for item in packages) + ")")
print("architectures=(" + " ".join(quote(item) for item in architectures) + ")")
PY
)" || fail "unknown or invalid profile ${profile}" 2
  eval "$profile_vars"
  [[ -r "$OS_RELEASE" ]] || fail "cannot read ${OS_RELEASE}" 3
  unset ID VERSION_CODENAME VERSION_ID
  # shellcheck disable=SC1090
  . "$OS_RELEASE"
  if [[ "${ID:-}" != ubuntu || "${VERSION_CODENAME:-}" != "$ubuntu_codename" || "${VERSION_ID:-}" != "$ubuntu_version_id" ]]; then
    fail "refusing profile ${profile}: host is ${ID:-unknown} ${VERSION_CODENAME:-unknown} ${VERSION_ID:-unknown}, not Ubuntu ${ubuntu_codename} ${ubuntu_version_id}" 3
  fi
  architecture="$(dpkg --print-architecture)" || fail "cannot read host architecture" 3
  supported=0
  for candidate in "${architectures[@]}"; do
    [[ "$candidate" != "$architecture" ]] || supported=1
  done
  [[ "$supported" == 1 ]] || fail "unsupported architecture ${architecture}; expected ${architectures[*]}" 3
else
  # install-agent without a robot profile reads the image's own APT suite.
  profile_vars="$(python3 - "$BASELINES" <<'PY'
import json, shlex, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
print("agent_package=" + shlex.quote(doc["agentPackage"]))
print("ros_distro=" + shlex.quote(""))
print("packages=()")
PY
)" || fail "agent package name is missing" 2
  eval "$profile_vars"
  [[ -r "$OS_RELEASE" ]] || fail "cannot read ${OS_RELEASE}" 3
  unset VERSION_CODENAME VERSION_ID
  # shellcheck disable=SC1090
  . "$OS_RELEASE"
  ubuntu_codename="${VERSION_CODENAME:-}"
  ubuntu_version_id="${VERSION_ID:-}"
  [[ -n "$ubuntu_codename" ]] || fail "os-release has no VERSION_CODENAME" 3
fi

package_installed() {
  local package="$1" status
  status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null)" || return 1
  [[ "$status" == "install ok installed" || "$status" == "hold ok installed" ]]
}

missing=()
install_specs=()
if [[ "$mode" != "install-agent" && "$mode" != "install-sitl" ]]; then
for package in "${packages[@]}"; do
  if ! package_installed "$package"; then
    missing+=("$package")
    install_specs+=("$package")
  fi
done
fi

if [[ "$mode" == "check" ]]; then
  if ((${#missing[@]})); then
    fail "missing packages: ${missing[*]}" 4
  fi
  # Do not depend on .bashrc, a user's overlay/Conda, or inherited ROS_DISTRO.
  # rospack may create a cache: confine it to a disposable directory, not HOME.
  (
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    unset ROS_DISTRO ROS_VERSION ROS_PACKAGE_PATH CMAKE_PREFIX_PATH
    unset ROSLISP_PACKAGE_DIRECTORIES PYTHONHOME PYTHONPATH LD_LIBRARY_PATH
    export ROS_HOME
    ROS_HOME="$(mktemp -d)"
    trap 'rm -rf -- "$ROS_HOME"' EXIT
    export PYTHONDONTWRITEBYTECODE=1
    setup="/opt/ros/${ros_distro}/setup.bash"
    [[ -r "$setup" ]] || fail "missing ROS setup ${setup}" 4
    set +u
    # shellcheck disable=SC1090
    source "$setup" || fail "cannot load ROS setup ${setup}" 4
    set -u
    actual="$(rosversion -d)" || fail "cannot read ROS distro after sourcing ${setup}" 4
    [[ "$actual" == "$ros_distro" ]] || fail "ros distro is ${actual:-unset}, want ${ros_distro}" 4
    for ros_package in roscpp rospy roslaunch; do
      rospack find "$ros_package" >/dev/null || fail "cannot load ROS package ${ros_package}" 4
    done
    ros_python=python3
    [[ "$ros_distro" != melodic ]] || ros_python=python2
    "$ros_python" -c 'import rospy, roslaunch' || fail "cannot import ${ros_distro} ROS Python runtime" 4
    check_elf() {
      local path="$1" dependencies
      [[ -r "$path" ]] || fail "missing ROS runtime ${path}" 4
      dependencies="$(ldd "$path" 2>&1)" || fail "cannot load ${path}: ${dependencies}" 4
      if [[ "$dependencies" == *"not found"* ]]; then
        fail "unresolved libraries for ${path}: ${dependencies}" 4
      fi
    }
    [[ -x "/opt/ros/${ros_distro}/lib/rosout/rosout" ]] || fail "rosout is not executable" 4
    check_elf "/opt/ros/${ros_distro}/lib/rosout/rosout"
    if [[ "$profile" == fs150-focal-noetic ]]; then
      for ros_package in mavros mavros_extras; do
        rospack find "$ros_package" >/dev/null || fail "cannot load ROS package ${ros_package}" 4
      done
      [[ -x /opt/ros/noetic/lib/mavros/mavros_node ]] || fail "mavros_node is not executable" 4
      check_elf /opt/ros/noetic/lib/mavros/mavros_node
      check_elf /opt/ros/noetic/lib/libmavros_plugins.so
      check_elf /opt/ros/noetic/lib/libmavros_extras.so
      geoid_dir=/usr/share/GeographicLib/geoids
      [[ -s "$geoid_dir/egm96-5.pgm" ]] || fail "missing MAVROS geoid ${geoid_dir}/egm96-5.pgm" 4
      printf '0 0\n' | GeoidEval -d "$geoid_dir" -n egm96-5 >/dev/null || fail "MAVROS geoid cannot be loaded" 4
    fi
  )
  printf 'onboard-baseline: %s matches %s %s arch=%s user=%s (runtime load check; no hardware started)\n' \
    "$profile" "$ubuntu_codename" "$ros_distro" "$architecture" "$(id -un)"
  exit 0
fi

if [[ "$mode" == "snapshot" ]]; then
  printf 'profile=%s os=%s ros=%s arch=%s\n' "$profile" "$ubuntu_codename" "$ros_distro" "$(dpkg --print-architecture 2>/dev/null || uname -m)"
  if [[ -s /usr/share/GeographicLib/geoids/egm96-5.pgm ]]; then
    printf 'geoid=present\n'
  else
    printf 'geoid=absent\n'
  fi
  if [[ -f /usr/share/xgc2-agent/install-source ]]; then
    cat /usr/share/xgc2-agent/install-source
  else
    printf 'agent_source=unset\n'
  fi
  python3 - <<'PY'
import pathlib
path = pathlib.Path("/etc/xgc2/agent.env")
keys = [
    "XGC_AGENT_ID",
    "XGC_AGENT_DISPLAY_NAME",
    "XGC_AGENT_GRPC_ADDR",
    "XGC_CORE_ENDPOINT",
    "XGC_AGENT_ADVERTISED_ENDPOINT",
    "XGC_AGENT_DATA_DIR",
    "XGC_AGENT_MANAGED_ROOT",
    "XGC_PROCESS_DEFINITION_PLUGINS",
]
found = {}
if path.is_file():
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        found[key] = value
    print("envfile=present")
else:
    print("envfile=absent")
for key in keys:
    if key in found:
        print("env\t%s\t%s" % (key, found[key]))
PY
  if command -v apt-mark >/dev/null 2>&1; then
    while read -r package; do
      [[ -n "$package" ]] || continue
      dpkg-query -W -f='manual\t${Package}\t${Version}\t${Architecture}\n' "$package" 2>/dev/null || printf 'manual\t%s\tmissing\t\n' "$package"
    done < <(apt-mark showmanual | sort)
  fi
  exit 0
fi

[[ "$(id -u)" == "0" ]] || fail "${mode} must run as root" 1

export DEBIAN_FRONTEND=noninteractive
ensure_ros_source() {
  local ros_installer="${ROOT}/install-ros-apt-source.sh"
  if [[ ! -x "$ros_installer" ]]; then
    ros_installer="$(cd "$ROOT/.." && pwd)/scripts/build/install-ros-apt-source.sh"
  fi
  [[ -x "$ros_installer" ]] || fail "ROS apt source installer is not beside the baseline" 1
  if [[ ! -e /etc/apt/sources.list.d/ros1.list ]]; then
    "$ros_installer" "$ros_distro" "$ubuntu_codename"
  fi
}
ensure_xgc2_source() {
  if [[ -e /etc/apt/sources.list.d/xgc2.list ]]; then
    return 0
  fi
  local tmp found
  tmp="$(mktemp)"
  curl -fsSL --retry 3 --connect-timeout 20 --max-time 120 https://xgc2.apt.xiaokang.ink/xgc2-archive-keyring.gpg -o "$tmp"
  found="$(gpg --batch --show-keys --with-fingerprint --with-colons "$tmp" | awk -F: '$1=="fpr"{print toupper($10)}' | sort -u)"
  [[ "$found" == "$XGC2_APT_FINGERPRINT" ]] || fail "XGC2 APT key fingerprint mismatch" 1
  install -d -m 0755 /etc/apt/keyrings
  install -m 0644 "$tmp" /etc/apt/keyrings/xgc2-archive-keyring.gpg
  rm -f "$tmp"
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/xgc2-archive-keyring.gpg] https://xgc2.apt.xiaokang.ink %s main\n' \
    "$(dpkg --print-architecture)" "$ubuntu_codename" > /etc/apt/sources.list.d/xgc2.list
}

if [[ "$mode" == "apply" ]]; then
  if ((${#install_specs[@]})); then
    ensure_ros_source
    apt-get update
    apt-get install -y --no-install-recommends "${install_specs[@]}"
  fi
  geoid_path=/usr/share/GeographicLib/geoids/egm96-5.pgm
  if [[ "$profile" == "fs150-focal-noetic" && ! -s "$geoid_path" ]]; then
    geographiclib-get-geoids -p /usr/share/GeographicLib egm96-5
  fi
  if [[ "$profile" == "fs150-focal-noetic" && ! -s "$geoid_path" ]]; then
    fail "MAVROS geoid was not installed at ${geoid_path}" 1
  fi
  bash "${ROOT}/onboard-baseline.sh" check --profile "$profile"
  printf 'onboard-baseline: applied %s\n' "$profile"
  exit 0
fi

# The optional simulator layer shares this installer with Dockerfile.sitl.
# Physical-machine apply never installs SITL or touches the running Agent.
if [[ "$mode" == "install-sitl" ]]; then
  [[ "$profile" == "fs150-focal-noetic" ]] || fail "SITL packages require the FS150 Focal/Noetic profile" 2
  simulation_packages=(ros-noetic-xgc2-gazebo-sim-fs150-sitl=1.1.0-23 ros-noetic-xgc2-px4-sitl-1-12=1.12.3-27)
  missing=()
  for spec in "${simulation_packages[@]}"; do
    installed="$(dpkg-query -W -f='${Version}' "${spec%%=*}" 2>/dev/null || true)"
    [[ "$installed" == "${spec#*=}" ]] || missing+=("$spec")
  done
  if ((${#missing[@]})); then
    ensure_xgc2_source
    apt-get update
    apt-get install -y --no-install-recommends "${missing[@]}"
  fi
  printf 'onboard-baseline: FS150 SITL packages installed\n'
  exit 0
fi

[[ -n "$agent_user" ]] || fail "install-agent requires --user with the existing robot account" 2
id "$agent_user" >/dev/null
agent_deb="${ONBOARD_BASELINE_AGENT_DEB:-}"
agent_version="${ONBOARD_BASELINE_AGENT_VERSION:-}"
if [[ -n "$agent_deb" ]]; then
  [[ -f "$agent_deb" ]] || fail "local agent deb is not a file: ${agent_deb}" 1
  # The image already contains the deb's install dependencies. Do not apt or
  # rescan the profile package list on this path; a later start finds the binary.
  dpkg -i "$agent_deb"
elif ! package_installed "$agent_package" || [[ -n "$agent_version" ]]; then
  ensure_xgc2_source
  apt-get update
  if [[ -n "$agent_version" ]]; then
    apt-get install -y --no-install-recommends "${agent_package}=${agent_version}"
  else
    apt-get install -y --no-install-recommends "$agent_package"
  fi
else
  printf 'onboard-baseline: %s is already installed\n' "$agent_package"
fi
package_installed "$agent_package" || fail "package ${agent_package} is not installed" 1
if [[ -n "$agent_version" ]]; then
  installed_version="$(dpkg-query -W -f='${Version}' "$agent_package")"
  [[ "$installed_version" == "$agent_version" ]] || fail "installed ${agent_package} ${installed_version}, want ${agent_version}" 1
fi

agent_env=/etc/xgc2/agent.env
# Package conffile: agent-01 and loopback are not a robot identity.
# A different robot ID already in the file is left unchanged, including its catalog line.
agent_id_from_file() {
  python3 - "$1" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
if not path.is_file():
    raise SystemExit(0)
for line in path.read_text(encoding="utf-8").splitlines():
    if line.startswith("XGC_AGENT_ID="):
        value = line.split("=", 1)[1].strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        print(value)
        break
PY
}
upsert_env_key() {
  python3 - "$agent_env" "$1" "$2" <<'PY'
import pathlib, sys
path, key, value = sys.argv[1:]
file = pathlib.Path(path)
lines = file.read_text(encoding="utf-8").splitlines() if file.exists() else []
prefix = key + "="
replaced = False
out = []
for line in lines:
    if line.startswith(prefix):
        out.append(prefix + value)
        replaced = True
    else:
        out.append(line)
if not replaced:
    out.append(prefix + value)
file.write_text("\n".join(out) + "\n", encoding="utf-8")
PY
}
write_default_agent_env() {
  cat >"$agent_env" <<'EOF'
# Headless XGC2 Agent. agent-01 is the package placeholder, not a robot identity.
XGC_AGENT_ID=agent-01
XGC_AGENT_DISPLAY_NAME="Agent 01"
XGC_AGENT_GRPC_ADDR=:9090
XGC_AGENT_ADVERTISED_ENDPOINT=127.0.0.1:9090
XGC_CORE_ENDPOINT=127.0.0.1:9092
XGC_AGENT_MANAGED_ROOT=/var/lib/xgc2-agent/managed
XGC_AGENT_DATA_DIR=/var/lib/xgc2-agent
XGC_AGENT_DOWNLOAD_HOSTS=github.com,objects.githubusercontent.com,release-assets.githubusercontent.com
XGC_PROCESS_DEFINITION_PLUGINS=/usr/share/xgc2-agent/process-definitions
EOF
  chown "root:$(id -gn "$agent_user")" "$agent_env"
  chmod 0640 "$agent_env" 2>/dev/null || chmod 0644 "$agent_env"
}
start_agent=0
if [[ -n "${XGC_AGENT_ID:-}" && -n "${XGC_CORE_ENDPOINT:-}" && -n "${XGC_AGENT_ADVERTISED_ENDPOINT:-}" && -n "${XGC_AGENT_DATA_DIR:-}" && -n "${XGC_AGENT_MANAGED_ROOT:-}" ]]; then
  install -d -m 0755 /etc/xgc2
  if [[ ! -f "$agent_env" ]]; then
    umask 027
    write_default_agent_env
  fi
  current_id="$(agent_id_from_file "$agent_env")"
  if [[ -n "$current_id" && "$current_id" != "agent-01" && "$current_id" != "$XGC_AGENT_ID" ]]; then
    printf 'onboard-baseline: keeping existing agent identity %s\n' "$current_id"
  else
    start_agent=1
    upsert_env_key XGC_AGENT_ID "$XGC_AGENT_ID"
    upsert_env_key XGC_CORE_ENDPOINT "$XGC_CORE_ENDPOINT"
    upsert_env_key XGC_AGENT_ADVERTISED_ENDPOINT "$XGC_AGENT_ADVERTISED_ENDPOINT"
    upsert_env_key XGC_AGENT_DATA_DIR "$XGC_AGENT_DATA_DIR"
    upsert_env_key XGC_AGENT_MANAGED_ROOT "$XGC_AGENT_MANAGED_ROOT"
    if [[ -n "${XGC_PROCESS_DEFINITION_PLUGINS:-}" ]]; then
      upsert_env_key XGC_PROCESS_DEFINITION_PLUGINS "$XGC_PROCESS_DEFINITION_PLUGINS"
    fi
    if [[ -n "${XGC_AGENT_DISPLAY_NAME:-}" ]]; then
      upsert_env_key XGC_AGENT_DISPLAY_NAME "\"${XGC_AGENT_DISPLAY_NAME}\""
    fi
    if [[ -n "${XGC_AGENT_GRPC_ADDR:-}" ]]; then
      upsert_env_key XGC_AGENT_GRPC_ADDR "$XGC_AGENT_GRPC_ADDR"
    fi
  fi
fi
current_id=""
if [[ -f "$agent_env" ]]; then
  current_id="$(agent_id_from_file "$agent_env")"
fi
/usr/lib/xgc2/configure-agent-user "$agent_user"
if [[ -d /run/systemd/system ]]; then
  if systemctl is-active --quiet xgc2-agent.service; then
    printf 'onboard-baseline: xgc2-agent.service already running\n'
  elif [[ "$start_agent" == 1 ]]; then
    systemctl enable --now xgc2-agent.service
  elif [[ -n "$current_id" && "$current_id" != "agent-01" ]]; then
    printf 'onboard-baseline: agent identity %s is configured; not restarting\n' "$current_id"
  else
    printf 'onboard-baseline: placeholder agent.env is not a robot identity; not starting xgc2-agent.service\n'
  fi
else
  printf 'onboard-baseline: no systemd; container entrypoint starts /usr/lib/xgc2/xgc-agent\n'
fi
printf 'onboard-baseline: installed %s on %s\n' "$agent_package" "${profile:-$ubuntu_codename}"
