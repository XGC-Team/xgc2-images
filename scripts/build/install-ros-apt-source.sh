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
apt-get install -y --no-install-recommends ca-certificates curl gnupg dirmngr

install -d /usr/share/keyrings
keyring=/usr/share/keyrings/ros-archive-keyring.gpg
rm -f "${keyring}"

curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc \
  | gpg --batch --yes --dearmor -o "${keyring}"

# snapshots.ros.org (Melodic final) is signed by the ROS snapshot key, not ros.asc.
import_extra_keys() {
  local key
  for key in "$@"; do
    gpg --batch --yes --no-default-keyring --keyring "${keyring}" \
      --keyserver hkps://keyserver.ubuntu.com \
      --recv-keys "${key}"
  done
}

case "${ros_distro}" in
  melodic)
    import_extra_keys AD19BAB3CBF125EA C1CF6E31E6BADE8868B172B4F42ED6FBAB17C654
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

apt-get clean
rm -rf /var/lib/apt/lists/*
