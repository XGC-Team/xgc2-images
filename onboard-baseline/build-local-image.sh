#!/usr/bin/env bash
# Local robot base image build. Agent installation happens when the
# container is prepared. This script does not push a registry tag.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINES="${ROOT}/onboard-baseline/baselines.json"
PROFILE="${1:-}"
PLATFORM="${2:-linux/amd64}"
MIRROR="${ONBOARD_APT_MIRROR:-http://mirrors.ustc.edu.cn/ubuntu}"

if [[ -z "$PROFILE" ]]; then
  echo "usage: build-local-image.sh <fs150-focal-noetic|scout-bionic-melodic|scout-focal-noetic|wheeltec-bionic-melodic> [linux/amd64|linux/arm64]" >&2
  echo "       PARENT_IMAGE=<image> build-local-image.sh fs150-focal-noetic-sitl" >&2
  exit 2
fi

case "$PLATFORM" in
  linux/amd64|linux/arm64) ;;
  *) echo "unsupported platform $PLATFORM" >&2; exit 2 ;;
esac

if [[ "$PROFILE" == "fs150-focal-noetic-sitl" ]]; then
  parent_tag="${PARENT_IMAGE:-onboard-sim-fs150-focal-noetic:base-local}"
  docker image inspect "$parent_tag" >/dev/null
  tag="onboard-sim-fs150-focal-noetic:base-local-sitl-1.1.0-23"
  echo "build-local-image: docker build -t ${tag}"
  echo "build-local-image: parent=${parent_tag}"
  DOCKER_BUILDKIT=1 docker build --platform "$PLATFORM" --pull=false \
    --build-arg "PARENT_IMAGE=${parent_tag}" \
    --build-arg "ONBOARD_APT_MIRROR=${MIRROR}" \
    -f "${ROOT}/apps/onboard-sim-fs150-focal-noetic/Dockerfile.sitl" \
    -t "$tag" \
    "$ROOT"
  entrypoint="$(docker image inspect "$tag" --format '{{json .Config.Entrypoint}}')"
  [[ "$entrypoint" == '["/opt/xgc2/onboard-baseline/image-entrypoint.sh"]' ]] || { echo "entrypoint changed: $entrypoint" >&2; exit 1; }
  docker image inspect "$tag" --format 'tag={{.RepoTags}} id={{.Id}}'
  echo "build-local-image: ${tag} is a local simulation layer, not a registry publication."
  exit 0
fi

case "$PROFILE" in
  fs150-focal-noetic) app=onboard-sim-fs150-focal-noetic; parent="ros:noetic-ros-base-focal" ;;
  scout-focal-noetic) app=onboard-sim-scout-focal-noetic; parent="ros:noetic-ros-base-focal" ;;
  scout-bionic-melodic) app=onboard-sim-scout-bionic-melodic; parent="ros:melodic-ros-base-bionic" ;;
  wheeltec-bionic-melodic) app=onboard-sim-wheeltec-bionic-melodic; parent="ros:melodic-ros-base-bionic" ;;
  *) echo "unknown profile $PROFILE" >&2; exit 2 ;;
esac

tag="onboard-sim-${PROFILE}:base-local"
echo "build-local-image: docker build -t ${tag}"
DOCKER_BUILDKIT=1 docker build --platform "$PLATFORM" --pull=false \
  --build-arg "PARENT_IMAGE=${parent}" \
  --build-arg "ONBOARD_APT_MIRROR=${MIRROR}" \
  -f "${ROOT}/apps/${app}/Dockerfile" \
  -t "$tag" \
  "$ROOT"
docker image inspect "$tag" --format 'tag={{.RepoTags}} id={{.Id}}'
echo "build-local-image: ${tag} has no Agent. install-agent is a later explicit step."
