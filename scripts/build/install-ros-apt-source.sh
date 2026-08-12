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

case "${ros_distro}" in
  melodic)
    curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc \
      | gpg --dearmor -o /usr/share/keyrings/ros-archive-keyring.gpg
    cat >/etc/apt/sources.list.d/ros1.list <<EOF
deb [signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://snapshots.ros.org/melodic/final/ubuntu ${ubuntu_codename} main
EOF
    ;;
  noetic)
    curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc \
      | gpg --dearmor -o /usr/share/keyrings/ros-archive-keyring.gpg
    cat >/etc/apt/sources.list.d/ros1.list <<EOF
deb [signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros/ubuntu ${ubuntu_codename} main
EOF
    ;;
  jazzy)
    curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc \
      | gpg --dearmor -o /usr/share/keyrings/ros-archive-keyring.gpg
    cat >/etc/apt/sources.list.d/ros2.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu ${ubuntu_codename} main
EOF
    ;;
  *)
    echo "unsupported ROS distro: ${ros_distro}" >&2
    exit 1
    ;;
esac

apt-get clean
rm -rf /var/lib/apt/lists/*
