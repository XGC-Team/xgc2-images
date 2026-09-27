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
  printf 'onboard-baseline: %s\n' "$*" >&2
  exit "${2:-1}"
}

mode="${1:-}"
shift || usage
if [[ "$mode" == "manualdiff" ]]; then
  before=""
  after=""
  while (($#)); do
    case "$1" in
      --before) before="${2:-}"; shift 2 ;;
      --after) after="${2:-}"; shift 2 ;;
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
    --profile) profile="${2:-}"; shift 2 ;;
    --user) agent_user="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$mode" == "check" || "$mode" == "apply" || "$mode" == "snapshot" || "$mode" == "install-agent" || "$mode" == "install-sitl" ]] || usage
if [[ "$mode" != "install-agent" && -z "$profile" ]]; then
  usage
fi
[[ -f "$BASELINES" ]] || usage

if [[ -n "$profile" ]]; then
  eval "$(python3 - "$BASELINES" "$profile" <<'PY'
import json, shlex, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
profile = doc["profiles"].get(sys.argv[2])
if profile is None:
    raise SystemExit(2)
print("ubuntu_codename=" + shlex.quote(profile["ubuntuCodename"]))
print("ubuntu_version_id=" + shlex.quote(profile["ubuntuVersionId"]))
print("ros_distro=" + shlex.quote(profile["rosDistro"]))
print("agent_package=" + shlex.quote(doc["agentPackage"]))
print("packages=(" + " ".join(shlex.quote(item) for item in profile["packages"]) + ")")
PY
)" || fail "unknown profile ${profile}" 2
  # shellcheck disable=SC1090
  . "$OS_RELEASE"
  if [[ "${VERSION_CODENAME:-}" != "$ubuntu_codename" || "${VERSION_ID:-}" != "$ubuntu_version_id" ]]; then
    fail "refusing profile ${profile}: host is ${VERSION_CODENAME:-unknown} ${VERSION_ID:-unknown}, not ${ubuntu_codename} ${ubuntu_version_id}" 3
  fi
else
  # install-agent without a robot profile reads the image's own APT suite.
  eval "$(python3 - "$BASELINES" <<'PY'
import json, shlex, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
print("agent_package=" + shlex.quote(doc["agentPackage"]))
print("ros_distro=" + shlex.quote(""))
print("packages=()")
PY
)" || fail "agent package name is missing" 2
  # shellcheck disable=SC1090
  . "$OS_RELEASE"
  ubuntu_codename="${VERSION_CODENAME:-}"
  ubuntu_version_id="${VERSION_ID:-}"
  [[ -n "$ubuntu_codename" ]] || fail "os-release has no VERSION_CODENAME" 3
fi

package_installed() {
  local package="$1" status
  status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)"
  [[ "$status" == "install ok installed" ]]
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
  if command -v rosversion >/dev/null 2>&1; then
    actual="$(rosversion -d 2>/dev/null || true)"
    [[ "$actual" == "$ros_distro" ]] || fail "ros distro is ${actual:-unset}, want ${ros_distro}" 4
  else
    fail "rosversion is not installed" 4
  fi
  if [[ "$profile" == "fs150-focal-noetic" && ! -s /usr/share/GeographicLib/geoids/egm96-5.pgm ]]; then
    fail "missing MAVROS geoid /usr/share/GeographicLib/geoids/egm96-5.pgm" 4
  fi
  printf 'onboard-baseline: %s matches %s %s\n' "$profile" "$ubuntu_codename" "$ros_distro"
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
