#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" != "0" ]]; then
  echo "install-packages.sh must run as root" >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "usage: install-packages.sh <package-list> [package-list...]" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

assert_not_xgc2() {
  local pkg="$1"
  if [[ "${pkg}" =~ (^|/)((lib)?xgc2-|ros-[a-z]+-xgc2-|ros-[a-z]+-sss-) ]]; then
    echo "refusing to install XGC2 product package: ${pkg}" >&2
    exit 1
  fi
}

collect_packages() {
  local file line pkg
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
      pkg="${line%% *}"
      assert_not_xgc2 "${pkg}"
      printf '%s\n' "${pkg}"
    done <"${file}"
  done
}

mapfile -t packages < <(collect_packages "$@" | awk 'NF && !seen[$0]++')
if [[ "${#packages[@]}" -eq 0 ]]; then
  echo "no packages to install"
  exit 0
fi

apt-get update
apt-get install -y --no-install-recommends "${packages[@]}"
apt-get clean
rm -rf /var/lib/apt/lists/*
