#!/usr/bin/env bash
set -euo pipefail
. /etc/os-release
test "${VERSION_CODENAME}" = "noble"
/usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh
set +u
source /opt/ros/jazzy/setup.bash
set -u
test "${ROS_DISTRO}" = "jazzy"
command -v rviz2 >/dev/null
native_vrpn_probe="$(mktemp)"
trap 'rm -f "${native_vrpn_probe}"' EXIT
# The router profile is private; distribution libraries are unchanged.
sha256sum --check --status <<'SHA256'
ea2bc9f761ce42c9b7d079f106059857557f037077cfc74b087aa945c80ab521  /usr/local/share/xgc2/vrpn-native/sources.lock.json
SHA256
python3 - <<'PYTHON'
import hashlib
import json
import subprocess
from pathlib import Path

source = Path("/usr/local/share/xgc2/vrpn-native")
lock_bytes = (source / "sources.lock.json").read_bytes()
lock = json.loads(lock_bytes)
patch = source / lock["vrpn"]["patch"]
assert hashlib.sha256(patch.read_bytes()).hexdigest() == lock["vrpn"]["patch_sha256"]
assert hashlib.sha256(Path("/opt/xgc2/vrpn-native/xgc2-vrpn-router-native.json").read_bytes()).digest() == hashlib.sha256(lock_bytes).digest()
official = Path("/opt/xgc2/vrpn-official")
manifest = json.loads((official / "xgc2-vrpn-official.json").read_text())
assert manifest["source_lock_sha256"] == hashlib.sha256(lock_bytes).hexdigest()
assert manifest["commit"] == lock["vrpn"]["commit"] and manifest["patched"] is False
# The upstream print-devices help entry is no arguments; --help is a tracker name.
for tool, args in (("vrpn_server", ["--help"]), ("vrpn_print_devices", [])):
    reply = subprocess.run([str(official / "bin" / tool), *args], capture_output=True, timeout=5)
    assert reply.returncode == 0 and b"Usage:" in reply.stdout + reply.stderr
PYTHON
# Link the patched profile marker and current resolver API from static archives;
# a system 07.34/1.15 header or library cannot satisfy this consumer.
c++ -std=c++20 -I/opt/xgc2/vrpn-native/include -x c++ - -x none \
  /opt/xgc2/vrpn-native/lib/libvrpnserver.a \
  /opt/xgc2/vrpn-native/lib/libquat.a \
  /opt/xgc2/vrpn-native/lib/libcares.a \
  $(pkg-config --libs libusb-1.0) -lpthread -o "${native_vrpn_probe}" <<'CPP'
#include <ares.h>
#include <ares_version.h>
#include <vrpn_Connection.h>

static_assert(VRPN_XGC_NATIVE_PROFILE == 20261009);
static_assert(ARES_VERSION_MAJOR == 1 && ARES_VERSION_MINOR == 34 && ARES_VERSION_PATCH == 8);
int main() {
  if (vrpn_xgc_native_profile() != VRPN_XGC_NATIVE_PROFILE) return 1;
  if (ares_library_init(ARES_LIB_INIT_ALL) != ARES_SUCCESS) return 1;
  ares_channel_t* channel = nullptr;
  if (ares_init(&channel) != ARES_SUCCESS) return 1;
  const auto result = ares_process_fds(channel, nullptr, 0, ARES_PROCESS_FLAG_NONE);
  ares_cancel(channel);
  ares_destroy(channel);
  ares_library_cleanup();
  return result == ARES_SUCCESS ? 0 : 1;
}
CPP
"${native_vrpn_probe}"
if dpkg-query -W -f='${Package}\n' | grep -E '^(lib)?xgc2-|ros-[a-z]+-xgc2-'; then
  echo "XGC2 packages leaked into build image" >&2
  exit 1
fi
