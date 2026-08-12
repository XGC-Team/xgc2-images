#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" != "0" ]]; then
  echo "install-ros-packages.sh must run as root" >&2
  exit 1
fi

ros_distro="${1:-}"
shift || true
if [[ -z "${ros_distro}" || $# -lt 1 ]]; then
  echo "usage: install-ros-packages.sh <ros-distro> <package-list> [package-list...]" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

assert_not_xgc2() {
  local pkg="$1"
  if [[ "${pkg}" =~ xgc2 ]] || [[ "${pkg}" =~ ros-[a-z]+-sss- ]]; then
    echo "refusing to install XGC2 product package: ${pkg}" >&2
    exit 1
  fi
}

expand_pkg() {
  local raw="$1"
  if [[ "${raw}" == ros-* ]]; then
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

apt-get update
apt-get install -y --no-install-recommends "${packages[@]}"
apt-get clean
rm -rf /var/lib/apt/lists/*
