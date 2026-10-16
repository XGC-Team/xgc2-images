#!/usr/bin/env bash
# Local robot base image build. Agent installation happens when the
# container is prepared. This script does not push a registry tag.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-}"
PLATFORM="${2:-linux/amd64}"
MIRROR="${ONBOARD_APT_MIRROR:-http://mirrors.ustc.edu.cn/ubuntu}"

if [[ -z "$PROFILE" || $# -gt 2 ]]; then
  echo "usage: build-local-image.sh <fs150-focal-noetic|scout-bionic-melodic|scout-focal-noetic|wheeltec-bionic-melodic> [linux/amd64|linux/arm64]" >&2
  echo "       PARENT_IMAGE=<image> build-local-image.sh fs150-focal-noetic-sitl [linux/amd64]" >&2
  exit 2
fi
case "$PLATFORM" in
  linux/amd64|linux/arm64) ;;
  *) echo "unsupported platform $PLATFORM" >&2; exit 2 ;;
esac
# Preserve the legacy omitted-platform tag; explicit targets coexist locally.
suffix=""
[[ $# -lt 2 ]] || suffix="-${PLATFORM#linux/}"
check_platform() {
  local actual
  actual="$(docker image inspect "$1" --format '{{.Os}}/{{.Architecture}}')"
  [[ "$actual" == "$PLATFORM" ]] || { echo "image $1 has $actual; expected $PLATFORM" >&2; return 1; }
}

if [[ "$PROFILE" == "fs150-focal-noetic-sitl" ]]; then
  [[ "$PLATFORM" == linux/amd64 ]] || { echo 'arm64 SITL packages have not been validated' >&2; exit 2; }
  parent_tag="${PARENT_IMAGE:-onboard-sim-fs150-focal-noetic:base-local${suffix}}"
  check_platform "$parent_tag"
  tag="onboard-sim-fs150-focal-noetic:base-local${suffix}-sitl-1.1.0-23"
  echo "build-local-image: docker build -t ${tag}"
  echo "build-local-image: parent=${parent_tag}"
  DOCKER_BUILDKIT=1 docker build --platform "$PLATFORM" --pull=false \
    --build-arg "PARENT_IMAGE=${parent_tag}" \
    --build-arg "ONBOARD_APT_MIRROR=${MIRROR}" \
    -f "${ROOT}/apps/onboard-sim-fs150-focal-noetic/Dockerfile.sitl" \
    -t "$tag" "$ROOT"
  check_platform "$tag"
  entrypoint="$(docker image inspect "$tag" --format '{{json .Config.Entrypoint}}')"
  [[ "$entrypoint" == '["/opt/xgc2/onboard-baseline/image-entrypoint.sh"]' ]] || { echo "entrypoint changed: $entrypoint" >&2; exit 1; }
  docker image inspect "$tag" --format 'tag={{.RepoTags}} id={{.Id}}'
  echo "build-local-image: ${tag} is a local simulation layer, not a registry publication."
  exit 0
fi

case "$PROFILE" in
  fs150-focal-noetic|scout-focal-noetic|scout-bionic-melodic|wheeltec-bionic-melodic) app="onboard-sim-${PROFILE}" ;;
  *) echo "unknown profile $PROFILE" >&2; exit 2 ;;
esac

tag="onboard-sim-${PROFILE}:base-local${suffix}"
echo "build-local-image: docker build -t ${tag}"
# The Dockerfile owns its parent default, including the W06 ros-core choice.
# fs150 stays on that APT Agent stage unless ONBOARD_AGENT_DEB names a package.
build_args=(
  --platform "$PLATFORM"
  --pull=false
  --build-arg "ONBOARD_APT_MIRROR=${MIRROR}"
)
agent_context=""
source_agent=0
if [[ -n "${ONBOARD_AGENT_DEB:-}" ]]; then
  [[ "$PROFILE" == "fs150-focal-noetic" ]] || {
    echo "build-local-image: ONBOARD_AGENT_DEB is only the fs150 source candidate" >&2
    exit 2
  }
  [[ -f "$ONBOARD_AGENT_DEB" ]] || {
    echo "build-local-image: ONBOARD_AGENT_DEB is not a file" >&2
    exit 2
  }
  package="$(dpkg-deb -f "$ONBOARD_AGENT_DEB" Package)"
  deb_arch="$(dpkg-deb -f "$ONBOARD_AGENT_DEB" Architecture)"
  deb_version="$(dpkg-deb -f "$ONBOARD_AGENT_DEB" Version)"
  [[ "$package" == "xgc2-agent" && "$deb_arch" == "${PLATFORM#linux/}" && -n "$deb_version" ]] || {
    echo "build-local-image: ONBOARD_AGENT_DEB must be xgc2-agent for ${PLATFORM#linux/}" >&2
    exit 2
  }
  agent_context="$(mktemp -d)"
  cp "$ONBOARD_AGENT_DEB" "$agent_context/xgc2-agent.deb"
  build_args+=(--build-arg AGENT_INSTALL=source --build-context "agentdeb=${agent_context}")
  source_agent=1
fi
set +e
DOCKER_BUILDKIT=1 docker build "${build_args[@]}" \
  -f "${ROOT}/apps/${app}/Dockerfile" -t "$tag" "$ROOT"
status=$?
set -e
if [[ -n "$agent_context" ]]; then
  rm -rf "$agent_context"
fi
[[ "$status" -eq 0 ]] || exit "$status"
check_platform "$tag"
docker image inspect "$tag" --format 'tag={{.RepoTags}} id={{.Id}}'
if [[ "$source_agent" == 1 ]]; then
  echo "build-local-image: ${tag} installs the supplied source-built Agent. This script does not publish the image."
else
  echo "build-local-image: ${tag} installs live xgc2-agent from APT while building. This script does not publish the image."
fi
