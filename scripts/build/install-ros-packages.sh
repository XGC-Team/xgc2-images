#!/usr/bin/env bash
set -euo pipefail

dry_run=0
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=1
  shift
fi

if [[ "${dry_run}" -ne 1 && "$(id -u)" != "0" ]]; then
  echo "install-ros-packages.sh must run as root" >&2
  exit 1
fi

ros_distro="${1:-}"
shift || true
if [[ -z "${ros_distro}" || $# -lt 1 ]]; then
  echo "usage: install-ros-packages.sh [--dry-run] <ros-distro> <package-list> [package-list...]" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

assert_not_xgc2() {
  local pkg="$1"
  if [[ "${pkg}" =~ ^(lib)?xgc2- ]] ||
     [[ "${pkg}" =~ ^ros-[a-z0-9]+-xgc2- ]] ||
     [[ "${pkg}" =~ ^ros-[a-z0-9]+-sss- ]] ||
     [[ "${pkg}" == scout-msgs ]] ||
     [[ "${pkg}" == swarm-ros-bridge ]] ||
     [[ "${pkg}" == livox-ros-driver ]] ||
     [[ "${pkg}" =~ ^arx5- ]] ||
     [[ "${pkg}" =~ ^b2- ]] ||
     [[ "${pkg}" =~ ^ros-[a-z0-9]+-(arx5|b2|scout|livox|swarm)- ]]; then
    echo "refusing to install XGC2 product package: ${pkg}" >&2
    exit 1
  fi
}

# Short names (ros-base, rviz, ros-gz-sim) become ros-<distro>-<name>.
# Only skip prefixing when the name is already this distro's fully qualified
# package (ros-noetic-ros-base). Matching any ros-* would leave ros-base
# unprefixed and apt would look for a package that does not exist.
expand_pkg() {
  local raw="$1"
  if [[ "${raw}" == "ros-${ros_distro}-"* ]]; then
    printf '%s\n' "${raw}"
    return
  fi
  printf 'ros-%s-%s\n' "${ros_distro}" "${raw}"
}

packages=()
for file in "$@"; do
  [[ -f "${file}" ]] || {
    echo "missing package list: ${file}" >&2
    exit 1
  }
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "${line}" ]] && continue
    pkg="$(expand_pkg "${line%% *}")"
    assert_not_xgc2 "${pkg}"
    packages+=("${pkg}")
  done <"${file}"
done

if [[ "${#packages[@]}" -eq 0 ]]; then
  echo "no ROS packages to install"
  exit 0
fi

mapfile -t packages < <(printf '%s\n' "${packages[@]}" | awk 'NF && !seen[$0]++')

if [[ "${dry_run}" -eq 1 ]]; then
  printf '%s\n' "${packages[@]}"
  exit 0
fi

apt-get update

# Humble ros-gz is published for amd64 but not arm64; skip any name whose
# candidate is (none) on this architecture instead of failing the whole layer.
arch="$(dpkg --print-architecture)"
available=()
skipped=()
for pkg in "${packages[@]}"; do
  candidate="$(apt-cache policy "${pkg}" | awk '/Candidate:/ {print $2; exit}')"
  if [[ -z "${candidate}" || "${candidate}" == "(none)" ]]; then
    echo "skipping unavailable ROS package on ${arch}: ${pkg}" >&2
    skipped+=("${pkg}")
    continue
  fi
  available+=("${pkg}")
done

if [[ "${#skipped[@]}" -gt 0 ]]; then
  echo "skipped ${#skipped[@]} ROS package(s) not in the ${arch} index" >&2
fi

if [[ "${#available[@]}" -eq 0 ]]; then
  echo "none of the requested ROS packages are available on ${arch}" >&2
  exit 1
fi

apt-get install -y --no-install-recommends "${available[@]}"
apt-get clean
rm -rf /var/lib/apt/lists/*
