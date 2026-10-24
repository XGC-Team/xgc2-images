#!/usr/bin/env bash
# Local project builder on an existing onboard-baseline profile.
#
# The image tag is the one build-local-image.sh already writes
# (onboard-sim-<profile>:latest). This script does not build or
# publish that image. A foreign architecture is the engine's existing
# platform switch; this script does not select a cross compiler and does not
# register host interpreters.
#
# The run is a builder container. Runtime images keep their own lifecycle.
# The daemon is on the host and does not have this helper's install path, so
# the helper is not a bind mount. The container is:
#   docker run -i --entrypoint /bin/bash IMAGE -s -- --internal-run
# and this script is the container's stdin. This run passes a unique --cidfile.
# A normal exit still uses --rm. Cancel, or a non-zero CLI exit, stops and
# removes only the container id that file recorded. An empty cidfile does not
# select a container by name.
#
# Source, compiler cache, work, and the publish directory are the absolute
# paths given to this command. They are not copied onto a robot. The default
# cache is ${XDG_CACHE_HOME:-$HOME/.cache}/xgc2/onboard-builder, one tree per
# profile and architecture. The build command runs the project build script
# and then packs a top-level .deb and/or install-space.tar. When the build
# wrote install/, the project install script is copied beside that archive
# as project-install.sh and is not executed here. robotInstall in the
# manifest stays not-run. The target Agent runs that script.
#
# prepare --role runtime is the shared profile prepare for an image build and
# a real machine. It runs onboard-baseline.sh check. Apply runs only when that
# check is not ready, and only as root. A ready profile is reused. The same
# project-owned script then runs with ONBOARD_PREPARE=runtime.
# prepare --role build runs that same script with ONBOARD_PREPARE=build and
# does not apply the profile. The build command does not prepare.
set -euo pipefail

die() {
  printf 'build-local-project: %s\n' "$*" >&2
  exit 2
}

fail() {
  printf 'build-local-project: %s\n' "$*" >&2
  exit 1
}

py() {
  python3 - "$@" <<'PY'
import json
import os
import shutil
import sys
import tarfile
from pathlib import Path

BANNED = {".git", "devel"}
SHIPPED_INSTALL = "project-install.sh"
MAGIC = b"!<arch>\n"

def fail(message, code=1):
    sys.stderr.write("build-local-project: %s\n" % message)
    raise SystemExit(code)

def banned(path):
    return any(part in BANNED for part in path.parts)

def link_inside(root, link):
    base = os.path.abspath(str(root))
    prefix = base.rstrip("/") + "/"
    current = os.path.abspath(str(link))
    seen = set()
    for _ in range(8):
        if current in seen or not os.path.lexists(current):
            return False
        if not os.path.islink(current):
            return current == base or current.startswith(prefix)
        seen.add(current)
        raw = os.readlink(current)
        if not raw or os.path.isabs(raw):
            return False
        current = os.path.normpath(os.path.join(os.path.dirname(current), raw))
        if current != base and not current.startswith(prefix):
            return False
    return False

def walk_files(root):
    files = []
    for path in sorted(root.rglob("*")):
        rel = path.relative_to(root)
        if banned(rel):
            fail("output contains %s" % rel.as_posix())
        if path.is_symlink():
            if not link_inside(root, path):
                fail("symlink escapes %s" % rel.as_posix())
            continue
        if path.is_file():
            files.append(path)
    return files

def scan(stage):
    if not stage.is_dir():
        fail("missing output stage")
    found = []
    for child in sorted(stage.iterdir(), key=lambda item: item.name):
        if child.is_symlink():
            fail("output contains a symlink")
        if child.is_file() and child.name.endswith(".deb") and child.name != ".deb":
            with open(str(child), "rb") as handle:
                magic = handle.read(8)
            if magic != MAGIC:
                fail("%s is not a deb archive" % child.name)
            found.append(("deb", child.name))
            continue
        if child.is_dir() and child.name == "install":
            walk_files(child)
            if not any(path.is_file() for path in child.rglob("*")):
                fail("install space is empty")
            found.append(("install-space", "install"))
            continue
        fail("unexpected output %s" % child.name)
    if not found:
        fail("no deb or install space")
    return found

def publish(stage, dest, profile, arch, ubuntu, ros, user, image, build_rel, install_script):
    found = scan(stage)
    artifacts = []
    writes = []
    for kind, name in found:
        if kind == "deb":
            artifacts.append({
                "kind": "deb",
                "name": name,
                "installed": False,
            })
            writes.append(("deb", stage / name, dest / name))
            continue
        if not install_script or not os.path.isfile(install_script):
            fail("install space requires the project install script")
        artifacts.append({
            "kind": "install-space",
            "name": "install-space.tar",
            "installScript": SHIPPED_INSTALL,
            "agentArgv": [SHIPPED_INSTALL],
            "agentEnv": ["ONBOARD_INSTALL", "ONBOARD_DEST"],
            "installed": False,
        })
        writes.append(("tar", stage / "install", dest / "install-space.tar"))
        writes.append(("script", install_script, dest / SHIPPED_INSTALL))
    manifest = {
        "profile": profile,
        "arch": arch,
        "ubuntuCodename": ubuntu,
        "rosDistro": ros,
        "username": user,
        "builderImage": image,
        "buildScript": build_rel,
        "installed": False,
        "robotInstall": "not-run",
        "artifacts": artifacts,
    }
    dest.mkdir(parents=True, exist_ok=True)
    for kind, source, target in writes:
        if kind == "deb":
            shutil.copy2(str(source), str(target))
        elif kind == "script":
            shutil.copy2(str(source), str(target))
            os.chmod(str(target), 0o755)
        else:
            with tarfile.open(str(target), "w", dereference=False) as archive:
                archive.add(str(source), arcname="install")
    (dest / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

command = sys.argv[1]
if command == "profile":
    data = json.loads(Path(sys.argv[2]).read_text())
    name, arch = sys.argv[3], sys.argv[4]
    profile = data.get("profiles", {}).get(name)
    if profile is None:
        fail("unknown profile %s" % name, 2)
    if arch not in profile.get("architectures", []):
        fail("profile %s has no architecture %s" % (name, arch), 2)
    sys.stdout.write("\t".join([
        profile["ubuntuCodename"],
        profile["rosDistro"],
        profile["username"],
    ]))
elif command == "scan":
    scan(Path(sys.argv[2]))
elif command == "publish":
    publish(
        Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], sys.argv[5],
        sys.argv[6], sys.argv[7], sys.argv[8], sys.argv[9], sys.argv[10],
        sys.argv[11],
    )
else:
    fail("unknown helper %s" % command)
PY
}

under_tree() {
  python3 - "$1" "$2" <<'PY'
import sys
from pathlib import Path
root = Path(sys.argv[1]).resolve()
raw = Path(sys.argv[2])
if raw.is_symlink() or not raw.is_file():
    raise SystemExit(1)
candidate = raw.resolve()
if root != candidate and root not in candidate.parents:
    raise SystemExit(1)
PY
}

internal_run() {
  [[ $# -eq 0 ]] || die "--internal-run takes no arguments"
  [[ -n "${ONBOARD_SOURCE:-}" && -d "$ONBOARD_SOURCE" ]] || fail "ONBOARD_SOURCE is not a directory"
  [[ -n "${ONBOARD_OUTPUT:-}" && -d "$ONBOARD_OUTPUT" ]] || fail "ONBOARD_OUTPUT is not a directory"
  [[ -n "${ONBOARD_CACHE:-}" && -d "$ONBOARD_CACHE" ]] || fail "ONBOARD_CACHE is not a directory"
  [[ -n "${ONBOARD_WORK:-}" && -d "$ONBOARD_WORK" ]] || fail "ONBOARD_WORK is not a directory"
  [[ -n "${ONBOARD_BUILD:-}" && -x "$ONBOARD_BUILD" ]] || fail "build script is not executable"
  ( cd "$ONBOARD_SOURCE" && "$ONBOARD_BUILD" )
  py scan "$ONBOARD_OUTPUT" >/dev/null
}

prepare_deps() {
  local role="" profile="" source="" script="" baseline check_status
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile) profile="${2:-}"; shift 2 ;;
      --source) source="${2:-}"; shift 2 ;;
      --script) script="${2:-}"; shift 2 ;;
      --role) role="${2:-}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [[ "$role" == "runtime" || "$role" == "build" ]] || die "prepare role must be runtime or build"
  [[ -n "$profile" && -n "$source" && -n "$script" ]] || die "usage: build-local-project.sh prepare --profile NAME --source DIR --script REL --role runtime|build"
  [[ "$profile" =~ ^[a-z0-9-]+$ ]] || die "profile name is not a baseline id"
  [[ -d "$source" ]] || die "source is not a directory"
  case "$script" in
    ""|/*|..|../*|*/../*|*/..) die "prepare script must stay inside the source tree" ;;
  esac
  source="$(cd "$source" && pwd)"
  under_tree "$source" "$source/$script" || die "prepare script must stay inside the source tree"
  [[ -x "$source/$script" ]] || die "prepare script is not executable"
  baseline="${ONBOARD_BASELINE_BIN:-${ROOT}/onboard-baseline.sh}"
  [[ -x "$baseline" ]] || fail "baseline script is not executable"
  if [[ "$role" == "runtime" ]]; then
    set +e
    "$baseline" check --profile "$profile"
    check_status=$?
    set -e
    if [[ "$check_status" -ne 0 ]]; then
      [[ "$check_status" -eq 4 ]] || exit "$check_status"
      [[ "$(id -u)" == "0" ]] || fail "prepare needs root to apply profile ${profile}"
      "$baseline" apply --profile "$profile"
      set +e
      "$baseline" check --profile "$profile"
      check_status=$?
      set -e
      [[ "$check_status" -eq 0 ]] || exit "$check_status"
    fi
  fi
  (
    cd "$source"
    ONBOARD_PREPARE="$role" ONBOARD_PROFILE="$profile" ONBOARD_SOURCE="$source" \
      "$source/$script"
  )
}

if [[ "${1:-}" == "--internal-run" ]]; then
  shift
  internal_run "$@"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASELINES="${ROOT}/baselines.json"

if [[ "${1:-}" == "prepare" ]]; then
  shift
  prepare_deps "$@"
  exit 0
fi

profile=""
arch=""
source=""
build=""
install=""
output=""
cache_root=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile="${2:-}"; shift 2 ;;
    --arch) arch="${2:-}"; shift 2 ;;
    --source) source="${2:-}"; shift 2 ;;
    --build) build="${2:-}"; shift 2 ;;
    --install) install="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    --cache-root) cache_root="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$profile" && -n "$arch" && -n "$source" && -n "$build" && -n "$output" ]] || die "usage: build-local-project.sh --profile NAME --arch amd64|arm64 --source DIR --build REL --output DIR [--install REL] [--cache-root DIR]"
[[ "$arch" == "amd64" || "$arch" == "arm64" ]] || die "architecture must be amd64 or arm64"
[[ "$profile" =~ ^[a-z0-9-]+$ ]] || die "profile name is not a baseline id"
[[ -d "$source" ]] || die "source is not a directory"
case "$build" in
  ""|/*|..|../*|*/../*|*/..) die "build script must stay inside the source tree" ;;
esac
source="$(cd "$source" && pwd)"
under_tree "$source" "$source/$build" || die "build script must stay inside the source tree"
[[ -x "$source/$build" ]] || die "build script is not executable"
if [[ -n "$install" ]]; then
  case "$install" in
    ""|/*|..|../*|*/../*|*/..) die "install script must stay inside the source tree" ;;
  esac
  under_tree "$source" "$source/$install" || die "install script must stay inside the source tree"
  [[ -x "$source/$install" ]] || die "install script is not executable"
fi
meta="$(py profile "$BASELINES" "$profile" "$arch")"
IFS=$'\t' read -r ubuntu ros username <<<"$meta"
[[ -n "$ubuntu" && -n "$ros" && -n "$username" ]] || die "profile metadata is incomplete"
if [[ -e "$output" ]]; then
  [[ -d "$output" ]] || die "output is not a directory"
  [[ -z "$(ls -A "$output")" ]] || die "output directory is not empty"
else
  mkdir -p "$output"
fi
output="$(cd "$output" && pwd)"

cache_root="${cache_root:-${XDG_CACHE_HOME:-$HOME/.cache}/xgc2/onboard-builder}"
mkdir -p "$cache_root"
cache_root="$(cd "$cache_root" && pwd)"
slot="${cache_root}/${profile}/${arch}"
mkdir -p "$slot"
lock="${slot}/lock"
if ! mkdir "$lock"; then
  die "a build for ${profile} ${arch} is already running"
fi
lock_held=1
remove_lock() {
  [[ "${lock_held:-0}" == 1 ]] || return 0
  rmdir "$lock" 2>/dev/null || true
  lock_held=0
}
runner="${BUILDER_RUNNER:-docker}"
cidfile=""
reaped=0
reap_container() {
  if [[ "$reaped" == 1 ]]; then
    return 0
  fi
  reaped=1
  if [[ -z "$cidfile" || ! -s "$cidfile" ]]; then
    return 0
  fi
  local cid
  cid="$(tr -d '[:space:]' <"$cidfile")"
  if [[ ! "$cid" =~ ^[0-9a-f]{64}$ ]]; then
    return 0
  fi
  "$runner" stop "$cid" >/dev/null 2>&1 || true
  "$runner" rm -f "$cid" >/dev/null 2>&1 || true
}
runner_pid=""
on_signal() {
  if [[ -n "$runner_pid" ]]; then
    kill -TERM "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    runner_pid=""
  fi
  reap_container
  remove_lock
  exit 130
}
trap on_signal TERM INT
trap remove_lock EXIT

cache_dir="${slot}/cache"
work_dir="${slot}/work"
stage_dir="${slot}/stage"
mkdir -p "$cache_dir" "$work_dir"
rm -rf "$stage_dir"
mkdir -p "$stage_dir"

image="onboard-sim-${profile}:latest"
cidfile="${slot}/cid"
rm -f "$cidfile"
argv=(
  run
  -i
  --rm
  --cidfile "$cidfile"
  --name "onboard-builder-${profile}-${arch}-$$"
  --platform "linux/${arch}"
  --entrypoint /bin/bash
  -v "${source}:/src:ro"
  -v "${cache_dir}:/cache"
  -v "${work_dir}:/work"
  -v "${stage_dir}:/output"
  -e "ONBOARD_PROFILE=${profile}"
  -e "ONBOARD_ARCH=${arch}"
  -e "ONBOARD_UBUNTU=${ubuntu}"
  -e "ONBOARD_ROS=${ros}"
  -e "ONBOARD_USER=${username}"
  -e "ONBOARD_SOURCE=/src"
  -e "ONBOARD_CACHE=/cache"
  -e "ONBOARD_WORK=/work"
  -e "ONBOARD_OUTPUT=/output"
  -e "ONBOARD_BUILD=/src/${build}"
  -w /src
  "$image"
  -s
  --
  --internal-run
)
script_file="${BASH_SOURCE[0]}"
[[ -f "$script_file" ]] || die "builder script is not a file"

set +e
"$runner" "${argv[@]}" <"$script_file" &
runner_pid=$!
wait "$runner_pid"
status=$?
set -e
runner_pid=""
trap - TERM INT
if [[ "$status" -ne 0 ]]; then
  reap_container
  remove_lock
  exit "$status"
fi

py publish "$stage_dir" "$output" "$profile" "$arch" "$ubuntu" "$ros" "$username" "$image" "$build" "${install:+$source/$install}"
remove_lock
