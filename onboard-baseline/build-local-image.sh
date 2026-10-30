#!/usr/bin/env bash
# Build only the third-party robot base. Products use explicit build/deploy workflows.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-}"
PLATFORM="${2:-linux/amd64}"
if [[ $# -gt 2 ]]; then
  echo 'Only a profile and platform are accepted; product installation belongs to an explicit source build/deploy workflow.' >&2
  exit 2
fi
case "$PROFILE" in
  fs150-focal-noetic|scout-bionic-melodic|scout-focal-noetic|wheeltec-bionic-melodic) ;;
  *) echo 'Select an existing onboard baseline profile.' >&2; exit 2 ;;
esac
case "$PLATFORM" in
  linux/amd64|linux/arm64) ;;
  *) echo "Unsupported platform: $PLATFORM" >&2; exit 2 ;;
esac
for variable in ONBOARD_AGENT_DEB ONBOARD_BASELINE_AGENT_VERSION ONBOARD_BASELINE_XSIM_VERSION; do
  if [[ -n "${!variable:-}" ]]; then
    echo "$variable belongs to a source product build, not a third-party base." >&2
    exit 2
  fi
done
tag="onboard-sim-${PROFILE}:latest"
target_args=()
if [[ "$PROFILE" == fs150-focal-noetic ]]; then
  tag="onboard-sim-${PROFILE}:builder"
  target_args=(--target builder)
fi
script_lock="apps/onboard-sim-${PROFILE}/tool-scripts.json"
if [[ ! -f "$ROOT/$script_lock" ]]; then
  script_lock=onboard-baseline/tool-scripts.json
fi
DOCKER_BUILDKIT=1 docker build --platform "$PLATFORM" --pull "${target_args[@]}" \
  --build-context "tool-scripts=$(python3 "$ROOT/scripts/tool-scripts-context.py" --lock "$script_lock")" \
  --build-arg "ONBOARD_APT_MIRROR=${ONBOARD_APT_MIRROR:-}" \
  -f "${ROOT}/apps/onboard-sim-${PROFILE}/Dockerfile" -t "$tag" "$ROOT"
actual="$(docker image inspect "$tag" --format '{{.Os}}/{{.Architecture}}')"
[[ "$actual" == "$PLATFORM" ]] || { echo "Expected $PLATFORM, found $actual" >&2; exit 1; }
docker image inspect "$tag" --format 'tag={{.RepoTags}} id={{.Id}}'
