#!/usr/bin/env bash
# Host-side checks for the onboard baseline. No apt install, no image build,
# no systemd on the host. Mounts stay inside a user namespace.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${ROOT}/onboard-baseline.sh"
ENTRY="${ROOT}/image-entrypoint.sh"
bash -n "$BASE"
bash -n "$ENTRY"

fail() {
  printf 'freeze-check: %s\n' "$*" >&2
  exit 1
}

repo="$(cd "$ROOT/.." && pwd)"
bash -n "$ROOT/build-local-image.sh"
if grep -q '/home/lxk' "$ROOT/build-local-image.sh"; then
  fail "build-local-image.sh contains a machine-local path"
fi
if grep -Eq 'mirrors\.ustc|unset HTTP_PROXY' "$BASE"; then
  fail "onboard-baseline.sh rewrites the machine apt environment"
fi
if grep -q 'c7ddf5e3' "$repo/apps/onboard-sim-fs150-focal-noetic/Dockerfile.sitl"; then
  fail "Dockerfile.sitl hardcodes a parent digest"
fi
mapfile -t official < <(find "$repo/apps" -mindepth 2 -maxdepth 2 -path '*/onboard-sim-*/Dockerfile' | sort)
[[ "${#official[@]}" -eq 4 ]] || fail "expected four official Dockerfiles, found ${#official[@]}"
for dockerfile in "${official[@]}"; do
  if grep -q 'COPY onboard-baseline/ /' "$dockerfile" || grep -q 'onboard-baseline/.local' "$dockerfile"; then
    fail "official Dockerfile copies the onboard-baseline directory: $dockerfile"
  fi
  for needed in \
    onboard-baseline/baselines.json \
    onboard-baseline/onboard-baseline.sh \
    onboard-baseline/image-entrypoint.sh \
    onboard-baseline/image-healthcheck.sh \
    scripts/build/install-ros-apt-source.sh
  do
    if ! grep -q "COPY ${needed} " "$dockerfile"; then
      fail "official Dockerfile missing ${needed}: $dockerfile"
    fi
  done
  ignore="${dockerfile}.dockerignore"
  [[ -f "$ignore" ]] || fail "missing ${ignore}"
  if ! grep -qx 'onboard-baseline/.local' "$ignore"; then
    fail "${ignore} does not exclude onboard-baseline/.local"
  fi
  if ! grep -q 'id=onboard_agent_deb,required=false' "$dockerfile"; then
    fail "official Dockerfile lacks the optional agent secret: $dockerfile"
  fi
done

write_os() {
  local dest="$1" codename="$2" version="$3"
  printf 'VERSION_CODENAME=%s\nVERSION_ID=%s\n' "$codename" "$version" >"$dest"
}

common_stubs() {
  local bin="$1"
  mkdir -p "$bin"
  cat >"$bin/dpkg-query" <<'EOF'
#!/bin/bash
fmt=""
pkg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -W) shift ;;
    -f) fmt="$2"; shift 2 ;;
    -f*) fmt="${1#-f}"; shift ;;
    *) pkg="$1"; shift ;;
  esac
done
if [[ "$fmt" == *'${Status}'* ]]; then
  printf 'install ok installed\n'
elif [[ "$fmt" == *manual* ]]; then
  printf 'manual\t%s\t1.2.3\tamd64\n' "$pkg"
elif [[ "$fmt" == *'${Version}'* ]]; then
  printf '0.1.0-2\n'
else
  printf 'unexpected dpkg-query\n' >&2
  exit 1
fi
EOF
  cat >"$bin/dpkg" <<'EOF'
#!/bin/bash
[[ "${1:-}" == --print-architecture ]]
printf 'amd64\n'
EOF
  cat >"$bin/rosversion" <<'EOF'
#!/bin/bash
printf '%s\n' "${FAKE_ROS_DISTRO:?}"
EOF
  cat >"$bin/apt-mark" <<'EOF'
#!/bin/bash
[[ "${1:-}" == showmanual ]]
printf 'zeta-pkg\nalpha-pkg\n'
EOF
  cat >"$bin/apt-get" <<'EOF'
#!/bin/bash
printf 'apt-get must not run in freeze-check\n' >&2
exit 99
EOF
  cat >"$bin/curl" <<'EOF'
#!/bin/bash
printf 'curl must not run in freeze-check\n' >&2
exit 99
EOF
  cat >"$bin/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${FREEZE_EVIDENCE:?}/systemctl.invoked"
if [[ "${1:-}" == is-active ]]; then
  exit 1
fi
exit 0
EOF
  cat >"$bin/geographiclib-get-geoids" <<'EOF'
#!/bin/bash
parent=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-p" ]]; then parent="$arg"; fi
  prev="$arg"
done
printf '%s\n' "$*" >"${FREEZE_EVIDENCE:?}/geoid.invoked"
[[ "$parent" == /usr/share/GeographicLib ]]
mkdir -p "$parent/geoids"
printf 'pgm\n' >"$parent/geoids/egm96-5.pgm"
EOF
  chmod 755 "$bin"/*
}

run_ns() {
  local sandbox="$1"
  shift
  local -a env_args=()
  while [[ $# -gt 0 && "$1" == *=* ]]; do
    env_args+=("$1")
    shift
  done
  env -u ONBOARD_BASELINE_AGENT_DEB -u ONBOARD_BASELINE_AGENT_DEB_SHA256 \
      -u XGC_AGENT_ID -u XGC_CORE_ENDPOINT -u XGC_AGENT_ADVERTISED_ENDPOINT \
      -u XGC_AGENT_DATA_DIR -u XGC_AGENT_MANAGED_ROOT \
      -u XGC_PROCESS_DEFINITION_PLUGINS -u XGC_AGENT_DISPLAY_NAME \
      -u XGC_AGENT_GRPC_ADDR -u ROS_HOME -u ROS_LOG_DIR -u ROS_MASTER_URI \
      -u ROS_IP -u ROS_HOSTNAME \
      "${env_args[@]}" \
      unshare --user --map-root-user --mount --propagation private -- bash -c '
        set -euo pipefail
        sandbox="$1"
        shift
        mount --bind "$sandbox/etc-xgc2" /etc/xgc2
        if [[ -d "$sandbox/usr-share" ]]; then
          mount --bind "$sandbox/usr-share" /usr/share
        fi
        mkdir -p /usr/share/GeographicLib/geoids
        mount --bind "$sandbox/geoids" /usr/share/GeographicLib/geoids
        mount --bind "$sandbox/run-systemd" /run/systemd
        mount --bind "$sandbox/apt" /etc/apt
        exec "$@"
      ' bash "$sandbox" "$@"
}

new_sandbox() {
  local sandbox="$1" systemd_mode="$2"
  mkdir -p "$sandbox/bin" "$sandbox/etc-xgc2" "$sandbox/geoids" "$sandbox/apt" "$sandbox/evidence"
  if [[ "$systemd_mode" == present ]]; then
    mkdir -p "$sandbox/run-systemd/system"
  else
    mkdir -p "$sandbox/run-systemd"
  fi
  common_stubs "$sandbox/bin"
}

# manualdiff does not need the target OS.
snap_a="$(mktemp)"
snap_b="$(mktemp)"
trap 'rm -f "$snap_a" "$snap_b"' EXIT
printf 'profile=fs150-focal-noetic os=focal ros=noetic arch=amd64\ngeoid=present\nmanual\talpha-pkg\t1.2.3\tamd64\nmanual\tzeta-pkg\t1.2.3\tamd64\n' >"$snap_a"
cp "$snap_a" "$snap_b"
diff_out="$("$BASE" manualdiff --before "$snap_a" --after "$snap_b")"
[[ "$diff_out" == "manualdiff removed=0 added=0" ]] || fail "identical manualdiff: $diff_out"
printf 'manual\talpha-pkg\t1.2.3\tamd64\nmanual\tnew-pkg\t9\tamd64\n' >"$snap_b"
set +e
diff_out="$("$BASE" manualdiff --before "$snap_a" --after "$snap_b" 2>&1)"
diff_rc=$?
set -e
[[ "$diff_rc" -eq 1 ]] || fail "changed manualdiff rc=$diff_rc"
[[ "$diff_out" == *"- manual	zeta-pkg	1.2.3	amd64"* ]] || fail "missing removal: $diff_out"
[[ "$diff_out" == *"+ manual	new-pkg	9	amd64"* ]] || fail "missing addition: $diff_out"

work="$(mktemp -d)"
trap 'rm -rf "$work"; rm -f "$snap_a" "$snap_b"' EXIT

# FS150 check refuses a missing geoid and accepts a real file. Scout does not require it.
sandbox="$work/check-missing"
new_sandbox "$sandbox" absent
write_os "$sandbox/os-release" focal 20.04
set +e
run_ns "$sandbox" \
  PATH="$sandbox/bin:/usr/bin:/bin" \
  FAKE_ROS_DISTRO=noetic \
  ONBOARD_BASELINE_OS_RELEASE="$sandbox/os-release" \
  "$BASE" check --profile fs150-focal-noetic >"$sandbox/out" 2>"$sandbox/err"
rc=$?
set -e
[[ "$rc" -eq 4 ]] || fail "missing geoid check rc=$rc $(cat "$sandbox/err")"
[[ "$(cat "$sandbox/err")" == *egm96-5.pgm* ]] || fail "geoid error text missing"

sandbox="$work/check-present"
new_sandbox "$sandbox" absent
write_os "$sandbox/os-release" focal 20.04
printf 'pgm\n' >"$sandbox/geoids/egm96-5.pgm"
run_ns "$sandbox" \
  PATH="$sandbox/bin:/usr/bin:/bin" \
  FAKE_ROS_DISTRO=noetic \
  ONBOARD_BASELINE_OS_RELEASE="$sandbox/os-release" \
  "$BASE" check --profile fs150-focal-noetic >"$sandbox/out"
[[ "$(cat "$sandbox/out")" == *"fs150-focal-noetic matches focal noetic"* ]] || fail "present geoid check"

sandbox="$work/check-scout"
new_sandbox "$sandbox" absent
write_os "$sandbox/os-release" bionic 18.04
run_ns "$sandbox" \
  PATH="$sandbox/bin:/usr/bin:/bin" \
  FAKE_ROS_DISTRO=melodic \
  ONBOARD_BASELINE_OS_RELEASE="$sandbox/os-release" \
  "$BASE" check --profile scout-bionic-melodic >"$sandbox/out"
[[ "$(cat "$sandbox/out")" == *"scout-bionic-melodic matches bionic melodic"* ]] || fail "scout check required a geoid"

# Missing agent.env is seeded with the package catalog, then caller identity overlays it.
sandbox="$work/apply-default"
new_sandbox "$sandbox" absent
write_os "$sandbox/os-release" focal 20.04
run_ns "$sandbox" \
  PATH="$sandbox/bin:/usr/bin:/bin" \
  FAKE_ROS_DISTRO=noetic \
  FREEZE_EVIDENCE="$sandbox/evidence" \
  ONBOARD_BASELINE_OS_RELEASE="$sandbox/os-release" \
  XGC_AGENT_ID=robot-fs150 \
  XGC_CORE_ENDPOINT=172.30.251.250:9092 \
  XGC_AGENT_ADVERTISED_ENDPOINT=172.30.251.10:9090 \
  XGC_AGENT_DATA_DIR=/var/lib/xgc2-agent \
  XGC_AGENT_MANAGED_ROOT=/var/lib/xgc2-agent/managed \
  XGC_AGENT_DISPLAY_NAME='FS150 1' \
  XGC_PROCESS_DEFINITION_PLUGINS=/opt/robot/catalog \
  "$BASE" apply --profile fs150-focal-noetic >"$sandbox/out"
[[ -s "$sandbox/geoids/egm96-5.pgm" ]] || fail "apply did not install the geoid"
[[ "$(cat "$sandbox/evidence/geoid.invoked")" == "-p /usr/share/GeographicLib egm96-5" ]] || fail "geoid tool parent"
[[ ! -e "$sandbox/evidence/systemctl.invoked" ]] || fail "apply called systemctl without systemd"
python3 - "$sandbox/etc-xgc2/agent.env" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
need = {
    "XGC_AGENT_ID": "robot-fs150",
    "XGC_CORE_ENDPOINT": "172.30.251.250:9092",
    "XGC_AGENT_ADVERTISED_ENDPOINT": "172.30.251.10:9090",
    "XGC_AGENT_DISPLAY_NAME": '"FS150 1"',
    "XGC_PROCESS_DEFINITION_PLUGINS": "/opt/robot/catalog",
    "XGC_AGENT_DOWNLOAD_HOSTS": "github.com,objects.githubusercontent.com,release-assets.githubusercontent.com",
    "XGC_AGENT_GRPC_ADDR": ":9090",
}
found = {}
for line in text.splitlines():
    if line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    found[key] = value
missing = {key: value for key, value in need.items() if found.get(key) != value}
if missing:
    raise SystemExit("default agent.env mismatch %s\n%s" % (missing, text))
if "/usr/share/xgc2/process-definitions" in text:
    raise SystemExit("core catalog leaked into agent.env")
PY

# A different robot ID is not replaced, and the placeholder is not started.
sandbox="$work/apply-keep"
new_sandbox "$sandbox" present
write_os "$sandbox/os-release" focal 20.04
printf 'pgm\n' >"$sandbox/geoids/egm96-5.pgm"
cat >"$sandbox/etc-xgc2/agent.env" <<'EOF'
# keep-me
XGC_AGENT_ID=robot-kept
XGC_PROCESS_DEFINITION_PLUGINS=/opt/robot/kept
EOF
before="$(sha256sum "$sandbox/etc-xgc2/agent.env" | awk '{print $1}')"
run_ns "$sandbox" \
  PATH="$sandbox/bin:/usr/bin:/bin" \
  FAKE_ROS_DISTRO=noetic \
  FREEZE_EVIDENCE="$sandbox/evidence" \
  ONBOARD_BASELINE_OS_RELEASE="$sandbox/os-release" \
  XGC_AGENT_ID=robot-new \
  XGC_CORE_ENDPOINT=172.30.251.250:9092 \
  XGC_AGENT_ADVERTISED_ENDPOINT=172.30.251.10:9090 \
  XGC_AGENT_DATA_DIR=/var/lib/xgc2-agent \
  XGC_AGENT_MANAGED_ROOT=/var/lib/xgc2-agent/managed \
  "$BASE" apply --profile fs150-focal-noetic >"$sandbox/out"
after="$(sha256sum "$sandbox/etc-xgc2/agent.env" | awk '{print $1}')"
[[ "$before" == "$after" ]] || fail "existing robot identity was rewritten"
if [[ -f "$sandbox/evidence/systemctl.invoked" && "$(cat "$sandbox/evidence/systemctl.invoked")" == *enable* ]]; then
  fail "kept identity was enabled"
fi
[[ "$(cat "$sandbox/out")" == *"keeping existing agent identity robot-kept"* ]] || fail "keep message"
[[ "$(cat "$sandbox/out")" == *"not restarting"* ]] || fail "kept identity restart message"

sandbox="$work/apply-placeholder"
new_sandbox "$sandbox" present
write_os "$sandbox/os-release" focal 20.04
printf 'pgm\n' >"$sandbox/geoids/egm96-5.pgm"
printf 'XGC_AGENT_ID=agent-01\nXGC_PROCESS_DEFINITION_PLUGINS=/usr/share/xgc2-agent/process-definitions\n' >"$sandbox/etc-xgc2/agent.env"
run_ns "$sandbox" \
  PATH="$sandbox/bin:/usr/bin:/bin" \
  FAKE_ROS_DISTRO=noetic \
  FREEZE_EVIDENCE="$sandbox/evidence" \
  ONBOARD_BASELINE_OS_RELEASE="$sandbox/os-release" \
  "$BASE" apply --profile fs150-focal-noetic >"$sandbox/out"
if [[ -f "$sandbox/evidence/systemctl.invoked" && "$(cat "$sandbox/evidence/systemctl.invoked")" == *enable* ]]; then
  fail "placeholder agent was started"
fi
[[ "$(cat "$sandbox/out")" == *"not starting xgc2-agent.service"* ]] || fail "placeholder message"
[[ "$(cat "$sandbox/etc-xgc2/agent.env")" == *"/usr/share/xgc2-agent/process-definitions"* ]] || fail "package catalog dropped"

# Real identity may be enabled. The systemctl binary here is a stub.
sandbox="$work/apply-enable"
new_sandbox "$sandbox" present
write_os "$sandbox/os-release" focal 20.04
printf 'pgm\n' >"$sandbox/geoids/egm96-5.pgm"
printf 'XGC_AGENT_ID=agent-01\n' >"$sandbox/etc-xgc2/agent.env"
run_ns "$sandbox" \
  PATH="$sandbox/bin:/usr/bin:/bin" \
  FAKE_ROS_DISTRO=noetic \
  FREEZE_EVIDENCE="$sandbox/evidence" \
  ONBOARD_BASELINE_OS_RELEASE="$sandbox/os-release" \
  XGC_AGENT_ID=robot-fs150 \
  XGC_CORE_ENDPOINT=172.30.251.250:9092 \
  XGC_AGENT_ADVERTISED_ENDPOINT=172.30.251.10:9090 \
  XGC_AGENT_DATA_DIR=/var/lib/xgc2-agent \
  XGC_AGENT_MANAGED_ROOT=/var/lib/xgc2-agent/managed \
  "$BASE" apply --profile fs150-focal-noetic >"$sandbox/out"
[[ "$(cat "$sandbox/evidence/systemctl.invoked")" == *"enable --now xgc2-agent.service"* ]] || fail "enable was not requested: $(cat "$sandbox/evidence/systemctl.invoked")"

# Snapshot lists the on-disk default and a sorted manual set.
sandbox="$work/snapshot"
new_sandbox "$sandbox" absent
write_os "$sandbox/os-release" focal 20.04
printf 'pgm\n' >"$sandbox/geoids/egm96-5.pgm"
printf 'XGC_AGENT_ID=agent-01\nXGC_PROCESS_DEFINITION_PLUGINS=/usr/share/xgc2-agent/process-definitions\n' >"$sandbox/etc-xgc2/agent.env"
run_ns "$sandbox" \
  PATH="$sandbox/bin:/usr/bin:/bin" \
  FAKE_ROS_DISTRO=noetic \
  ONBOARD_BASELINE_OS_RELEASE="$sandbox/os-release" \
  "$BASE" snapshot --profile fs150-focal-noetic >"$sandbox/out"
python3 - "$sandbox/out" <<'PY'
import pathlib, sys
lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
manual = [line for line in lines if line.startswith("manual\t")]
if manual != ["manual\talpha-pkg\t1.2.3\tamd64", "manual\tzeta-pkg\t1.2.3\tamd64"]:
    raise SystemExit("manual order %s" % manual)
text = "\n".join(lines)
for needle in (
    "geoid=present",
    "envfile=present",
    "env\tXGC_AGENT_ID\tagent-01",
    "env\tXGC_PROCESS_DEFINITION_PLUGINS\t/usr/share/xgc2-agent/process-definitions",
):
    if needle not in text:
        raise SystemExit("snapshot missing %s\n%s" % (needle, text))
PY

# Entrypoint: Docker catalog and ROS master win. Unset ROS_HOME becomes the xgc2 home.
entry_stubs() {
  local bin="$1"
  mkdir -p "$bin"
  cat >"$bin/id" <<'EOF'
#!/bin/bash
[[ "${1:-}" == xgc2 ]]
EOF
  cat >"$bin/systemd-tmpfiles" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >"${ENTRYPOINT_EVIDENCE:?}/tmpfiles.invoked"
EOF
  cat >"$bin/install" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${ENTRYPOINT_EVIDENCE:?}/install.invoked"
seen=0
for arg in "$@"; do
  if [[ "$arg" == -- ]]; then seen=1; continue; fi
  if [[ "$seen" -eq 1 ]]; then mkdir -p "$arg"; fi
done
EOF
  cat >"$bin/runuser" <<'EOF'
#!/bin/bash
if [[ "$1" == -u && "$2" == xgc2 && "$3" == -- && "$4" == test && "$5" == -w ]]; then
  [[ -w "$6" ]]
  exit
fi
if [[ "$1" == --preserve-environment && "$2" == -u && "$3" == xgc2 && "$4" == -- && "$5" == /usr/lib/xgc2/xgc-agent ]]; then
  {
    printf 'PLUGINS=%s\n' "${XGC_PROCESS_DEFINITION_PLUGINS-__unset__}"
    printf 'MASTER=%s\n' "${ROS_MASTER_URI-__unset__}"
    printf 'ROS_HOME=%s\n' "${ROS_HOME-__unset__}"
    printf 'ROS_LOG=%s\n' "${ROS_LOG_DIR-__unset__}"
    printf 'DISPLAY=%s\n' "${XGC_AGENT_DISPLAY_NAME-__unset__}"
    printf 'ADAPTER=%s\n' "${XGC_ADAPTER_RUNTIME_UDS-__unset__}"
    printf 'DATA=%s\n' "${XGC_AGENT_DATA_DIR-__unset__}"
    printf 'MANAGED=%s\n' "${XGC_AGENT_MANAGED_ROOT-__unset__}"
    printf 'USER=%s\n' "${USER-__unset__}"
  } >"${ENTRYPOINT_EVIDENCE:?}/exec.env"
  exit 0
fi
printf 'unexpected runuser: %s\n' "$*" >&2
exit 1
EOF
  chmod 755 "$bin"/*
}

run_entry() {
  local sandbox="$1"
  shift
  local -a env_args=()
  # /home is replaced inside the namespace, so the entrypoint must not live there.
  cp "$ENTRY" "$sandbox/image-entrypoint.sh"
  while [[ $# -gt 0 && "$1" == *=* ]]; do
    env_args+=("$1")
    shift
  done
  env -u XGC_PROCESS_DEFINITION_PLUGINS -u XGC_AGENT_DISPLAY_NAME \
      -u XGC_ADAPTER_RUNTIME_UDS -u XGC_ADAPTER_DEFINITION_PATHS -u XGC_ADAPTER_RUNTIME_DIR \
      -u XGC_AGENT_DATA_DIR -u XGC_AGENT_MANAGED_ROOT \
      -u ROS_MASTER_URI -u ROS_HOME -u ROS_LOG_DIR -u ROS_IP -u ROS_HOSTNAME \
      "${env_args[@]}" \
      ENTRYPOINT_EVIDENCE="$sandbox/evidence" \
      PATH="$sandbox/bin:/usr/bin:/bin" \
      ROS_DISTRO=noetic \
      unshare --user --map-root-user --mount --propagation private -- bash -c '
        set -euo pipefail
        sandbox="$1"; entry="$2"
        shift 2
        mount --bind "$sandbox/empty-systemd" /run/systemd
        mount --bind "$sandbox/etc-xgc2" /etc/xgc2
        mount --bind "$sandbox/tmpfiles" /usr/lib/tmpfiles.d
        mount --bind "$sandbox/setup.bash" /opt/ros/noetic/setup.bash
        mount --bind "$sandbox/varlib" /var/lib
        mount --bind "$sandbox/home" /home
        exec bash "$entry"
      ' bash "$sandbox" "$sandbox/image-entrypoint.sh"
}

sandbox="$work/entry-default-ros"
mkdir -p "$sandbox/bin" "$sandbox/etc-xgc2" "$sandbox/tmpfiles" "$sandbox/varlib/xgc2-agent" \
  "$sandbox/empty-systemd" "$sandbox/home/xgc2" "$sandbox/evidence"
entry_stubs "$sandbox/bin"
chmod 1777 "$sandbox/varlib/xgc2-agent" "$sandbox/home/xgc2"
cat >"$sandbox/etc-xgc2/agent.env" <<'EOF'
XGC_AGENT_ID=agent-01
XGC_AGENT_DISPLAY_NAME="Agent 01"
XGC_PROCESS_DEFINITION_PLUGINS=/usr/share/xgc2-agent/process-definitions
XGC_CORE_ENDPOINT=127.0.0.1:9092
EOF
printf 'd /run/xgc2/adapter 0750 xgc2 xgc2 -\n' >"$sandbox/tmpfiles/xgc2-agent.conf"
printf 'export ROS_MASTER_URI=http://localhost:11311\nexport ROS_HOME=/root/.ros\nexport ROS_SETUP_MARK=sourced\n' >"$sandbox/setup.bash"
run_entry "$sandbox" \
  XGC_PROCESS_DEFINITION_PLUGINS=/opt/robot/catalog \
  XGC_AGENT_DISPLAY_NAME='FS150 1' \
  XGC_ADAPTER_RUNTIME_UDS=/run/xgc2/adapter/runtime.sock \
  XGC_AGENT_DATA_DIR=/var/lib/xgc2-agent \
  XGC_AGENT_MANAGED_ROOT=/var/lib/xgc2-managed \
  ROS_MASTER_URI=http://10.64.0.2:11311
python3 - "$sandbox/evidence/exec.env" "$sandbox/evidence/install.invoked" "$sandbox/evidence/tmpfiles.invoked" <<'PY'
import pathlib, sys
env = dict(line.split("=", 1) for line in pathlib.Path(sys.argv[1]).read_text().splitlines())
install = pathlib.Path(sys.argv[2]).read_text()
tmpfiles = pathlib.Path(sys.argv[3]).read_text().strip()
assert env["PLUGINS"] == "/opt/robot/catalog", env
assert env["DISPLAY"] == "FS150 1", env
assert env["MASTER"] == "http://10.64.0.2:11311", env
assert env["ROS_HOME"] == "/home/xgc2/.ros", env
assert env["ROS_LOG"] == "/home/xgc2/.ros/log", env
assert env["ADAPTER"] == "/run/xgc2/adapter/runtime.sock", env
assert env["DATA"] == "/var/lib/xgc2-agent", env
assert env["MANAGED"] == "/var/lib/xgc2-managed", env
assert env["USER"] == "xgc2", env
assert "-o xgc2 -g xgc2" in install, install
assert "/home/xgc2/.ros" in install, install
assert "/var/lib/xgc2-agent" in install, install
assert "/var/lib/xgc2-managed" in install, install
assert tmpfiles == "--create /usr/lib/tmpfiles.d/xgc2-agent.conf", tmpfiles
PY

sandbox="$work/entry-caller-ros"
mkdir -p "$sandbox/bin" "$sandbox/etc-xgc2" "$sandbox/tmpfiles" "$sandbox/varlib/xgc2-agent" \
  "$sandbox/empty-systemd" "$sandbox/home/xgc2/custom-ros/log" "$sandbox/evidence"
entry_stubs "$sandbox/bin"
chmod -R 1777 "$sandbox/varlib/xgc2-agent" "$sandbox/home/xgc2"
printf 'XGC_PROCESS_DEFINITION_PLUGINS=/usr/share/xgc2-agent/process-definitions\n' >"$sandbox/etc-xgc2/agent.env"
printf 'd /run/xgc2/adapter 0750 xgc2 xgc2 -\n' >"$sandbox/tmpfiles/xgc2-agent.conf"
printf 'export ROS_HOME=/root/.ros\nexport ROS_MASTER_URI=http://localhost:11311\n' >"$sandbox/setup.bash"
run_entry "$sandbox" \
  ROS_HOME=/home/xgc2/custom-ros \
  ROS_LOG_DIR=/home/xgc2/custom-ros/log \
  ROS_MASTER_URI=http://172.30.251.250:11311
python3 - "$sandbox/evidence/exec.env" <<'PY'
import pathlib, sys
env = dict(line.split("=", 1) for line in pathlib.Path(sys.argv[1]).read_text().splitlines())
assert env["ROS_HOME"] == "/home/xgc2/custom-ros", env
assert env["ROS_LOG"] == "/home/xgc2/custom-ros/log", env
assert env["MASTER"] == "http://172.30.251.250:11311", env
assert env["PLUGINS"] == "/usr/share/xgc2-agent/process-definitions", env
assert env["ADAPTER"] == "__unset__", env
PY
install_text="$(cat "$sandbox/evidence/install.invoked")"
[[ "$install_text" != *"/home/xgc2/custom-ros"* ]] || fail "caller ROS_HOME was recreated"
[[ "$install_text" == *"/var/lib/xgc2-agent"* ]] || fail "persist data dir was not prepared"

write_transport_stubs() {
  local bin="$1"
  cat >"$bin/apt-get" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${FREEZE_EVIDENCE:?}/apt-get.invoked"
exit 0
EOF
  cat >"$bin/curl" <<'EOF'
#!/bin/bash
out=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == -o ]]; then out="$arg"; fi
  prev="$arg"
done
[[ -n "$out" ]]
printf 'key\n' >"$out"
EOF
  cat >"$bin/gpg" <<'EOF'
#!/bin/bash
printf 'fpr:::::::::2A8E11B36F56D307ADF626D85E5FDC30979EA43F:\n'
EOF
  cat >"$bin/dpkg-query" <<'EOF'
#!/bin/bash
fmt=""
pkg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -W) shift ;;
    -f) fmt="$2"; shift 2 ;;
    -f*) fmt="${1#-f}"; shift ;;
    *) pkg="$1"; shift ;;
  esac
done
if [[ "$fmt" == *'${Status}'* ]]; then
  if [[ "$pkg" == xgc2-agent ]]; then
    printf 'not-installed\n'
  else
    printf 'install ok installed\n'
  fi
elif [[ "$fmt" == *'${Version}'* ]]; then
  printf '0.1.0-2\n'
else
  printf 'unexpected dpkg-query\n' >&2
  exit 1
fi
EOF
  chmod 755 "$bin"/apt-get "$bin"/curl "$bin"/gpg "$bin"/dpkg-query
}

prepare_apt_tree() {
  local sandbox="$1"
  new_sandbox "$sandbox" absent
  write_os "$sandbox/os-release" focal 20.04
  printf 'pgm\n' >"$sandbox/geoids/egm96-5.pgm"
  mkdir -p "$sandbox/apt/sources.list.d"
  printf 'deb http://archive.ubuntu.com/ubuntu focal main\n' >"$sandbox/apt/sources.list"
  : >"$sandbox/apt/sources.list.d/ros1.list"
  write_transport_stubs "$sandbox/bin"
}

sandbox="$work/apply-signed-apt"
prepare_apt_tree "$sandbox"
run_ns "$sandbox" \
  PATH="$sandbox/bin:/usr/bin:/bin" \
  FAKE_ROS_DISTRO=noetic \
  FREEZE_EVIDENCE="$sandbox/evidence" \
  ONBOARD_BASELINE_OS_RELEASE="$sandbox/os-release" \
  XGC_AGENT_ID=robot-fs150 \
  XGC_CORE_ENDPOINT=10.64.90.251:9092 \
  XGC_AGENT_ADVERTISED_ENDPOINT=10.64.90.101:9090 \
  XGC_AGENT_DATA_DIR=/var/lib/xgc2-agent \
  XGC_AGENT_MANAGED_ROOT=/var/lib/xgc2-managed \
  "$BASE" apply --profile fs150-focal-noetic >"$sandbox/out"
grep -q 'archive.ubuntu.com' "$sandbox/apt/sources.list" || fail "signed apply rewrote the ubuntu source"
if grep -q 'mirrors.ustc' "$sandbox/apt/sources.list"; then
  fail "signed apply rewrote the machine mirror"
fi
grep -q 'xgc2.apt.xiaokang.ink' "$sandbox/apt/sources.list.d/xgc2.list" || fail "signed apply did not add the XGC2 index"
grep -q 'xgc2-agent=0.1.0-2' "$sandbox/evidence/apt-get.invoked" || fail "signed apply did not request the pinned agent"
[[ ! -e "$sandbox/evidence/dpkg.invoked" ]] || fail "signed apply installed a local deb"

sandbox="$work/apply-local-deb"
prepare_apt_tree "$sandbox"
mkdir -p "$sandbox/usr-share"
printf 'local-acceptance-deb\n' >"$sandbox/agent.deb"
local_sha="$(sha256sum "$sandbox/agent.deb" | awk '{print $1}')"
cat >"$sandbox/bin/dpkg" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == --print-architecture ]]; then
  printf 'amd64\n'
  exit 0
fi
if [[ "${1:-}" == -i ]]; then
  printf '%s\n' "$*" >"${FREEZE_EVIDENCE:?}/dpkg.invoked"
  exit 0
fi
printf 'unexpected dpkg\n' >&2
exit 1
EOF
chmod 755 "$sandbox/bin/dpkg"
run_ns "$sandbox" \
  PATH="$sandbox/bin:/usr/bin:/bin" \
  FAKE_ROS_DISTRO=noetic \
  FREEZE_EVIDENCE="$sandbox/evidence" \
  ONBOARD_BASELINE_OS_RELEASE="$sandbox/os-release" \
  ONBOARD_BASELINE_AGENT_DEB="$sandbox/agent.deb" \
  ONBOARD_BASELINE_AGENT_DEB_SHA256="$local_sha" \
  XGC_AGENT_ID=robot-fs150 \
  XGC_CORE_ENDPOINT=10.64.90.251:9092 \
  XGC_AGENT_ADVERTISED_ENDPOINT=10.64.90.101:9090 \
  XGC_AGENT_DATA_DIR=/var/lib/xgc2-agent \
  XGC_AGENT_MANAGED_ROOT=/var/lib/xgc2-managed \
  "$BASE" apply --profile fs150-focal-noetic >"$sandbox/out"
grep -q 'archive.ubuntu.com' "$sandbox/apt/sources.list" || fail "local deb apply rewrote the ubuntu source"
[[ ! -e "$sandbox/apt/sources.list.d/xgc2.list" ]] || fail "local deb apply added the signed index"
grep -q -- "-i $sandbox/agent.deb" "$sandbox/evidence/dpkg.invoked" || fail "local deb was not installed: $(cat "$sandbox/evidence/dpkg.invoked")"
if grep -q 'xgc2-agent=' "$sandbox/evidence/apt-get.invoked"; then
  fail "local deb apply also requested the agent from APT"
fi

printf 'freeze-check: passed\n'
