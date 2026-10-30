#!/usr/bin/env bash
# Stable interfaces are prepared; iterated products and hardware drivers are not.
set -euo pipefail
packages="$(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n')"
blocked="$(awk '$2 == "installed" {sub(/:[^:]+$/, "", $1); print $1}' <<<"$packages" | while IFS= read -r package; do
  # This simulation base also supplies the published FS150 flight simulator.
  # The package closure is explicit; other robot bases retain the interface-only boundary.
  if [[ "${ONBOARD_BASELINE_PROFILE:-}" == fs150-focal-noetic ]]; then
    case "$package" in
      # D15-approved formal coordination message package; FS150 runtime only.
      ros-noetic-xgc2-runtime-sync|\
      ros-noetic-xgc2-gazebo-sim-fs150-sitl|ros-noetic-xgc2-px4-sitl-1-12|\
      ros-noetic-xgc2-gazebo-sim-px4-1-12|ros-noetic-xgc2-fs150-description|\
      ros-noetic-xgc2-simple-lidar|ros-noetic-xgc2-gazebo-scene) continue ;;
    esac
  fi
  # Interface families only. Installation versions and dependency closure belong
  # to the shared preparation profile and the signed APT package metadata.
  # xgc2-zenoh is the published APT-owned SDK foundation (exact 1.8.0 pin in
  # runtime-packages.txt); it is not an iterated product or a physical driver.
  case "$package" in
    libxgc2-math-dev|libxgc2-math-*-dev|libxgc2-state-machine-dev|\
    libxgc2-xrpc*|node-xgc2-xrpc|node-xgc2-xrpc-client|\
    libxgc2-chassis-hold*|libxgc2-hover-thrust*|\
    xgc2-protobuf-dev|xgc2-acados|xgc2-zenoh|\
    ros-*-xgc2-*-msgs|ros-*-scout-msgs|ros-*-xgc2-ros1-utils|\
    ros-noetic-xgc2-estimator-hover-thrust) continue ;;
  esac
  if [[ "$package" =~ ^(xsim$|libxgc2|xgc2-|ros-[a-z0-9]+-(xgc2-|sss-|scout-|wheeltec-|livox-|px4-multirotor-controller|ugv-controller|velodyne-driver|ouster-ros)|scout-msgs$|swarm-ros-bridge$|livox-ros-driver$|nvidia-(driver|dkms|jetpack)|linux-image-) ]]; then
    printf '%s\n' "$package"
  fi
done)"
if [[ -n "$blocked" ]]; then
  printf '%s\n' "$blocked" >&2
  echo 'Robot bases must not contain iterated products, undeclared first-party software or physical drivers.' >&2
  exit 1
fi
