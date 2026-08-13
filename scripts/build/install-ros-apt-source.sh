#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" != "0" ]]; then
  echo "install-ros-apt-source.sh must run as root" >&2
  exit 1
fi

ros_distro="${1:-}"
ubuntu_codename="${2:-}"
if [[ -z "${ros_distro}" || -z "${ubuntu_codename}" ]]; then
  echo "usage: install-ros-apt-source.sh <ros-distro> <ubuntu-codename>" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
. /etc/os-release
if [[ "${VERSION_CODENAME}" != "${ubuntu_codename}" ]]; then
  echo "image codename ${VERSION_CODENAME} does not match ${ubuntu_codename}" >&2
  exit 1
fi

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg

install -d /usr/share/keyrings
keyring=/usr/share/keyrings/ros-archive-keyring.gpg
rm -f "${keyring}"

GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
chmod 700 "${GNUPGHOME}"
cleanup_gpg() {
  rm -rf "${GNUPGHOME}"
}
trap cleanup_gpg EXIT

import_asc() {
  curl -fsSL "$1" | gpg --batch --yes --import
}

import_keyid() {
  local keyid="$1"
  curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x${keyid}" \
    | gpg --batch --yes --import
}

import_asc https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc

case "${ros_distro}" in
  melodic)
    # snapshots.ros.org is not signed by ros.asc.
    import_keyid AD19BAB3CBF125EA
    import_keyid C1CF6E31E6BADE8868B172B4F42ED6FBAB17C654
    cat >/etc/apt/sources.list.d/ros1.list <<EOF
deb [signed-by=${keyring}] http://snapshots.ros.org/melodic/final/ubuntu ${ubuntu_codename} main
EOF
    ;;
  noetic)
    cat >/etc/apt/sources.list.d/ros1.list <<EOF
deb [signed-by=${keyring}] http://packages.ros.org/ros/ubuntu ${ubuntu_codename} main
EOF
    ;;
  humble | jazzy)
    cat >/etc/apt/sources.list.d/ros2.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=${keyring}] http://packages.ros.org/ros2/ubuntu ${ubuntu_codename} main
EOF
    ;;
  *)
    echo "unsupported ROS distro: ${ros_distro}" >&2
    exit 1
    ;;
esac

gpg --batch --yes --export --output "${keyring}"
chmod 0644 "${keyring}"

apt-get clean
rm -rf /var/lib/apt/lists/*
