#!/usr/bin/env bash
# Select the Ubuntu mirror and HTTPS for existing TUNA ROS entries.
# Keep suites, components and signing keys intact.
set -euo pipefail
case "$(dpkg --print-architecture)" in
  amd64|i386) archive=ubuntu ;;
  *) archive=ubuntu-ports ;;
esac
mirror="${ONBOARD_APT_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/$archive}"
mirror="${mirror%/}"
for sources in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
  [[ -f "$sources" ]] || continue
  sed -i -E \
    -e "s#https?://([[:alnum:]-]+\.)?archive\.ubuntu\.com/ubuntu/?#$mirror/#g" \
    -e "s#https?://security\.ubuntu\.com/ubuntu/?#$mirror/#g" \
    -e "s#https?://ports\.ubuntu\.com/ubuntu-ports/?#$mirror/#g" \
    -e "s#https?://mirrors\.(tuna\.tsinghua\.edu\.cn|ustc\.edu\.cn)/ubuntu(-ports)?/?#$mirror/#g" \
    -e "s#http://mirrors\.tuna\.tsinghua\.edu\.cn/ros/#https://mirrors.tuna.tsinghua.edu.cn/ros/#g" \
    "$sources"
done
