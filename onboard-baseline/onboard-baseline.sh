#!/usr/bin/env bash
# Idempotent base environment for onboard simulation images and real machines.
# check is read-only. apply installs only the profile package list and does not
# remove user packages, start a chassis, or start an experiment.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASELINES="${ROOT}/baselines.json"
OS_RELEASE="${ONBOARD_BASELINE_OS_RELEASE:-/etc/os-release}"
EGM96_5_URL="https://downloads.sourceforge.net/project/geographiclib/geoids-distrib/egm96-5.tar.bz2?use_mirror=autoselect"
# Observed SHA256 of that official archive. Not a signed upstream digest.
EGM96_5_ARCHIVE_SHA256="c46224f8f723dc915d97179f4e1580a98d6c742fe2b82cd8fef0ecaaad13e614"

usage() {
  echo "usage: onboard-baseline.sh check|apply|snapshot --profile <fs150-focal-noetic|scout-bionic-melodic|scout-focal-noetic|wheeltec-bionic-melodic>" >&2
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
while (($#)); do
  case "$1" in
    --profile) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || usage; profile="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$mode" == "check" || "$mode" == "apply" || "$mode" == "snapshot" ]] || usage
if [[ -z "$profile" ]]; then
  usage
fi
[[ -f "$BASELINES" ]] || usage

# Melodic's ROS core parent has Python 2, not necessarily Python 3 yet.
# Read the same JSON with its existing interpreter; apply then installs python3
# from the profile. No bootstrap apt runs before profile/OS/architecture checks.
metadata_python=python3
if ! command -v "$metadata_python" >/dev/null 2>&1; then
  metadata_python=python
  command -v "$metadata_python" >/dev/null 2>&1 || fail "python3 or the existing Melodic python is required to read baselines.json" 2
fi

declare -A minimum_versions=()
if [[ -n "$profile" ]]; then
  profile_config="$("$metadata_python" - "$BASELINES" "$profile" <<'PY'
import io, json, sys
try:
    from shlex import quote
except ImportError:  # Python 2 on the Melodic ROS core parent
    from pipes import quote
doc = json.load(io.open(sys.argv[1], encoding="utf-8"))
profile = doc["profiles"].get(sys.argv[2])
if profile is None:
    raise SystemExit(2)
print("profile_user=" + quote(profile["username"]))
print("ubuntu_codename=" + quote(profile["ubuntuCodename"]))
print("ubuntu_version_id=" + quote(profile["ubuntuVersionId"]))
print("ros_distro=" + quote(profile["rosDistro"]))
print("architectures=(" + " ".join(quote(item) for item in profile["architectures"]) + ")")
print("packages=(" + " ".join(quote(item) for item in profile["packages"]) + ")")
print("minimum_versions=(" + " ".join("[" + quote(package) + "]=" + quote(version)
      for package, version in profile.get("minimumVersions", {}).items()) + ")")
PY
)" || fail "invalid or unknown profile ${profile}" 2
  eval "$profile_config"
  unset ID VERSION_CODENAME VERSION_ID
  # shellcheck disable=SC1090
  . "$OS_RELEASE"
  if [[ "${ID:-}" != "ubuntu" || "${VERSION_CODENAME:-}" != "$ubuntu_codename" || "${VERSION_ID:-}" != "$ubuntu_version_id" ]]; then
    fail "refusing profile ${profile}: host is ${ID:-unknown} ${VERSION_CODENAME:-unknown} ${VERSION_ID:-unknown}, not ubuntu ${ubuntu_codename} ${ubuntu_version_id}" 3
  fi
  host_arch="$(dpkg --print-architecture)" || fail "cannot read host architecture" 3
  arch_supported=0
  for architecture in "${architectures[@]}"; do
    [[ "$host_arch" != "$architecture" ]] || arch_supported=1
  done
  [[ "$arch_supported" == 1 ]] || fail "refusing profile ${profile}: unsupported architecture ${host_arch}; expected ${architectures[*]}" 3
  if [[ -n "${ONBOARD_BASELINE_USER:-}" && "$ONBOARD_BASELINE_USER" != "$profile_user" ]]; then
    fail "profile ${profile} user is ${profile_user}, not ${ONBOARD_BASELINE_USER}" 3
  fi
  if [[ "$mode" == check && "$(id -u)" != 0 && "$(id -un)" != "$profile_user" ]]; then
    fail "profile ${profile} must run as ${profile_user}" 3
  fi
  id "$profile_user" >/dev/null 2>&1 || fail "profile ${profile} account ${profile_user} does not exist" 3
fi

package_installed() {
  local package="$1" record status version minimum
  record="$(dpkg-query -W -f='${Status}\t${Version}' "$package" 2>/dev/null)" || return 1
  IFS=$'\t' read -r status version <<<"$record"
  [[ "$status" == "install ok installed" || "$status" == "hold ok installed" ]] || return 1
  minimum="${minimum_versions[$package]:-}"
  [[ -z "$minimum" ]] || dpkg --compare-versions "$version" ge "$minimum"
}

missing=()
install_specs=()
for package in "${packages[@]}"; do
  if ! package_installed "$package"; then
    missing+=("$package")
    install_specs+=("$package")
  fi
done

if [[ "$mode" == "check" ]]; then
  if ((${#missing[@]})); then
    fail "missing packages: ${missing[*]}" 4
  fi
  # No caller overlay, shell startup files or ROS master is needed. rospack
  # and roslaunch may write caches: keep those in a disposable home, not the
  # robot user's home. Nothing here starts ROS nodes or connects to hardware.
  check_runtime() (
    check_home="$(mktemp -d)" || return 1
    trap 'rm -rf -- "$check_home"' EXIT
    env -i HOME="$check_home" ROS_HOME="$check_home/.ros" PATH=/usr/sbin:/usr/bin:/sbin:/bin \
      LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 \
      bash --noprofile --norc -s -- "$ros_distro" "$profile" <<'ROS'
set -eo pipefail
ros_distro="$1"
profile="$2"
ros_prefix="/opt/ros/$ros_distro"
[[ -r "$ros_prefix/setup.bash" ]] || { echo "missing ROS setup: $ros_prefix/setup.bash" >&2; exit 1; }
# ROS setup reads optional variables, so enable nounset only after sourcing it.
source "$ros_prefix/setup.bash"
set -u
actual="$(rosversion -d)"
[[ "$actual" == "$ros_distro" ]] || { echo "ros distro is $actual, want $ros_distro" >&2; exit 1; }
for package in roscpp rospy roslaunch geometry_msgs nav_msgs; do
  rospack find "$package" >/dev/null
done
python=python3
[[ "$ros_distro" != melodic ]] || python=python
"$python" -B -c 'import rospy, roslaunch, rosbag; from geometry_msgs.msg import Twist; from nav_msgs.msg import Odometry'
if [[ "$profile" == fs150-focal-noetic ]]; then
  rospack find mavros >/dev/null
  "$python" -B -c 'from mavros_msgs.msg import State; from mavros_msgs.srv import CommandBool'
  node="$ros_prefix/lib/mavros/mavros_node"
  [[ -x "$node" ]] || { echo "missing MAVROS executable: $node" >&2; exit 1; }
  ldd "$node" >"$HOME/mavros-ldd.txt"
  if grep -q 'not found' "$HOME/mavros-ldd.txt"; then
    cat "$HOME/mavros-ldd.txt" >&2
    exit 1
  fi
  # --files resolves the installed launch graph without launching it.
  roslaunch --files mavros px4.launch >/dev/null
  geoid_dir=/usr/share/GeographicLib/geoids
  [[ -s "$geoid_dir/egm96-5.pgm" && -r "$geoid_dir/egm96-5.pgm" ]] || { echo "missing/unreadable MAVROS geoid: $geoid_dir/egm96-5.pgm" >&2; exit 1; }
  GeoidEval -d "$geoid_dir" -n egm96-5 --input-string '0 0' >/dev/null
fi

ROS
  )
  check_runtime || fail "runtime check failed for ${profile}" 4
  printf 'onboard-baseline: %s matches %s %s arch=%s user=%s account=%s\n' "$profile" "$ubuntu_codename" "$ros_distro" "$host_arch" "$(id -un)" "$profile_user"
  exit 0
fi

if [[ "$mode" == "snapshot" ]]; then
  printf 'profile=%s os=%s ros=%s arch=%s\n' "$profile" "$ubuntu_codename" "$ros_distro" "$(dpkg --print-architecture 2>/dev/null || uname -m)"
  printf 'runtime_user=%s\n' "$(id -un)"
  if [[ -s /usr/share/GeographicLib/geoids/egm96-5.pgm ]]; then
    printf 'geoid=present\n'
  else
    printf 'geoid=absent\n'
  fi
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
install_fs150_geoid() (
  local tmp actual member
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 --retry-max-time 300 "$EGM96_5_URL" -o "$tmp/egm96-5.tar.bz2"
  actual="$(sha256sum "$tmp/egm96-5.tar.bz2" | awk '{print tolower($1)}')"
  [[ "$actual" == "$EGM96_5_ARCHIVE_SHA256" ]] || fail "EGM96-5 archive SHA256 mismatch" 1
  tar -xjf "$tmp/egm96-5.tar.bz2" -C "$tmp" \
    geoids/egm96-5.pgm geoids/egm96-5.wld geoids/egm96-5.pgm.aux.xml
  for member in egm96-5.pgm egm96-5.wld egm96-5.pgm.aux.xml; do
    [[ -s "$tmp/geoids/$member" ]] || fail "EGM96-5 archive member missing or empty: ${member}" 1
  done
  install -d -m 0755 /usr/share/GeographicLib/geoids
  # A nonempty pgm is the apply skip key, so it is installed only after both sidecars.
  for member in egm96-5.wld egm96-5.pgm.aux.xml egm96-5.pgm; do
    install -m 0644 "$tmp/geoids/$member" "/usr/share/GeographicLib/geoids/$member"
  done
)

if [[ "$mode" == "apply" ]]; then
  if ((${#install_specs[@]})); then
    ensure_ros_source
    apt-get update
    apt-get install -y --no-install-recommends --no-remove "${install_specs[@]}"
  fi
  geoid_path=/usr/share/GeographicLib/geoids/egm96-5.pgm
  if [[ "$profile" == "fs150-focal-noetic" && ! -s "$geoid_path" ]]; then
    install_fs150_geoid
  fi
  if [[ "$profile" == "fs150-focal-noetic" && ! -s "$geoid_path" ]]; then
    fail "MAVROS geoid was not installed at ${geoid_path}" 1
  fi
  printf 'onboard-baseline: applied %s\n' "$profile"
  exit 0
fi
