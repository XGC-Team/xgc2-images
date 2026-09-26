#!/usr/bin/env bash
# Local image build. The four baselines require ONBOARD_BASELINE_AGENT_DEB.
# There is no default deb path. Signed APT is what the Dockerfiles do when
# that secret is omitted. This script does not push a registry tag.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINES="${ROOT}/onboard-baseline/baselines.json"
PROFILE="${1:-}"
MIRROR="${ONBOARD_APT_MIRROR:-http://mirrors.ustc.edu.cn/ubuntu}"

if [[ -z "$PROFILE" ]]; then
  echo "usage: ONBOARD_BASELINE_AGENT_DEB=<file> build-local-image.sh <fs150-focal-noetic|scout-bionic-melodic|scout-focal-noetic|wheeltec-bionic-melodic>" >&2
  echo "       PARENT_IMAGE=<image> build-local-image.sh fs150-focal-noetic-sitl" >&2
  exit 2
fi

if [[ "$PROFILE" == "fs150-focal-noetic-sitl" ]]; then
  parent_tag="${PARENT_IMAGE:-onboard-sim-fs150-focal-noetic:agent-0.1.0-2-local}"
  docker image inspect "$parent_tag" >/dev/null
  tag="onboard-sim-fs150-focal-noetic:agent-0.1.0-2-local-sitl-1.1.0-23"
  echo "build-local-image: docker build -t ${tag}"
  echo "build-local-image: parent=${parent_tag}"
  DOCKER_BUILDKIT=1 docker build --pull=false \
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

DEB="${ONBOARD_BASELINE_AGENT_DEB:-}"
[[ -n "$DEB" && -f "$DEB" ]] || { echo "set ONBOARD_BASELINE_AGENT_DEB to the local acceptance deb" >&2; exit 2; }

eval "$(python3 - "$BASELINES" "$PROFILE" <<'PY'
import json, shlex, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
profile = doc["profiles"].get(sys.argv[2])
if profile is None:
    raise SystemExit(2)
print("expected_version=" + shlex.quote(doc["agentVersion"]))
PY
)"

case "$PROFILE" in
  fs150-focal-noetic) app=onboard-sim-fs150-focal-noetic; parent="ros:noetic-ros-base-focal" ;;
  scout-focal-noetic) app=onboard-sim-scout-focal-noetic; parent="ros:noetic-ros-base-focal" ;;
  scout-bionic-melodic) app=onboard-sim-scout-bionic-melodic; parent="ros:melodic-ros-base-bionic" ;;
  wheeltec-bionic-melodic) app=onboard-sim-wheeltec-bionic-melodic; parent="ros:melodic-ros-base-bionic" ;;
  *) echo "unknown profile $PROFILE" >&2; exit 2 ;;
esac

tag="onboard-sim-${PROFILE}:agent-${expected_version}-local"
echo "build-local-image: docker build -t ${tag}"
echo "build-local-image: deb=${DEB}"
DOCKER_BUILDKIT=1 docker build --pull=false \
  --secret "id=onboard_agent_deb,src=${DEB}" \
  --build-arg "PARENT_IMAGE=${parent}" \
  --build-arg "ONBOARD_APT_MIRROR=${MIRROR}" \
  -f "${ROOT}/apps/${app}/Dockerfile" \
  -t "$tag" \
  "$ROOT"
docker image inspect "$tag" --format 'tag={{.RepoTags}} id={{.Id}}'
echo "build-local-image: ${tag} used the secret deb. A build without that secret installs xgc2-agent from the signed APT index."
