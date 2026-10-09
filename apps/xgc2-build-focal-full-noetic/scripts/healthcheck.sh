#!/usr/bin/env bash
set -euo pipefail
. /etc/os-release
test "${VERSION_CODENAME}" = "focal"
/usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh
test "$(rustc --version | awk '{print $2}')" = "1.93.0"
test "$(cargo --version | awk '{print $2}')" = "1.93.0"
set +u
source /opt/ros/noetic/setup.bash
set -u
test "${ROS_DISTRO}" = "noetic"
command -v rviz >/dev/null
command -v gazebo >/dev/null
dpkg-query -W ros-noetic-pcl-ros ros-noetic-pcl-conversions \
  ros-noetic-eigen-conversions ros-noetic-tf libgflags-dev \
  libgoogle-glog-dev libtbb-dev libyaml-cpp-dev libpcl-dev \
  libffmpeg-nvenc-dev nlohmann-json3-dev libglfw3-dev libglm-dev \
  libomp-10-dev libomp5-10 libc-ares-dev python3-grpcio >/dev/null
# Compile and link the GPU sensor headers without requiring a display or GPU.
gpu_probe="$(mktemp)"
grpc_probe="$(mktemp)"
native_vrpn_probe="$(mktemp)"
openmp_probe="$(mktemp -d)"
trap 'rm -f "${gpu_probe}" "${grpc_probe}" "${native_vrpn_probe}"; rm -rf "${openmp_probe}"' EXIT
# Use the same Clang/CMake discovery as the native GPU package.
cat >"${openmp_probe}/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.16)
project(FocalClangOpenMP LANGUAGES C CXX)
find_package(OpenMP REQUIRED COMPONENTS C CXX)
CMAKE
cmake -S "${openmp_probe}" -B "${openmp_probe}/build" \
  -DCMAKE_C_COMPILER=clang-10 -DCMAKE_CXX_COMPILER=clang++-10
c++ -std=c++17 -x c++ - -lglfw -o "${gpu_probe}" <<'CPP'
#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>
#include <glm/glm.hpp>
#include <glm/gtc/matrix_transform.hpp>
#include <glm/gtc/type_ptr.hpp>

int main() {
  int major = 0, minor = 0, revision = 0;
  glfwGetVersion(&major, &minor, &revision);
  const glm::mat4 model = glm::translate(glm::mat4(1.0f), glm::vec3(1.0f, 2.0f, 3.0f));
  const float* data = glm::value_ptr(model);
  return major == 3 && minor >= 3 && data[12] == 1.0f &&
      data[13] == 2.0f && data[14] == 3.0f ? 0 : 1;
}
CPP
"${gpu_probe}"
# Exercise the native completion queue and c-ares link used by the adapter client.
c++ -std=c++14 $(pkg-config --cflags grpc++ libcares) -x c++ - \
  $(pkg-config --libs grpc++ libcares) -o "${grpc_probe}" <<'CPP'
#include <ares.h>
#include <grpcpp/grpcpp.h>

int main() {
  if (ares_library_init(ARES_LIB_INIT_ALL) != ARES_SUCCESS) return 1;
  grpc::CompletionQueue queue;
  queue.Shutdown();
  void* tag = nullptr;
  bool ok = false;
  const bool event = queue.Next(&tag, &ok);
  ares_library_cleanup();
  return event ? 1 : 0;
}
CPP
"${grpc_probe}"
# The router profile remains private: system VRPN/c-ares above are unchanged.
sha256sum --check --status <<'SHA256'
ea2bc9f761ce42c9b7d079f106059857557f037077cfc74b087aa945c80ab521  /usr/local/share/xgc2/vrpn-native/sources.lock.json
SHA256
python3 - <<'PYTHON'
import hashlib
import json
from pathlib import Path

source = Path("/usr/local/share/xgc2/vrpn-native")
lock_bytes = (source / "sources.lock.json").read_bytes()
lock = json.loads(lock_bytes)
patch = source / lock["vrpn"]["patch"]
assert hashlib.sha256(patch.read_bytes()).hexdigest() == lock["vrpn"]["patch_sha256"]
assert hashlib.sha256(Path("/opt/xgc2/vrpn-native/xgc2-vrpn-router-native.json").read_bytes()).digest() == hashlib.sha256(lock_bytes).digest()
PYTHON
# Link the patched profile marker and current resolver API from static archives;
# a system 07.34/1.15 header or library cannot satisfy this consumer.
clang++-10 -std=c++20 -I/opt/xgc2/vrpn-native/include -x c++ - -x none \
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
python3 - <<'PY'
from concurrent import futures
from importlib.metadata import version
import grpc

grpc_version = version("grpcio")
print("Python gRPC", grpc_version)
assert tuple(map(int, grpc_version.split(".")[:2])) >= (1, 16)
with futures.ThreadPoolExecutor(max_workers=1) as executor:
    server = grpc.server(executor)
    handler = grpc.unary_unary_rpc_method_handler(lambda request, context: request)
    server.add_generic_rpc_handlers((grpc.method_handlers_generic_handler("probe", {"Echo": handler}),))
    server.stop(0)
with grpc.insecure_channel("localhost:1") as channel:
    assert callable(channel.unary_unary("/probe/Echo"))
PY
python3 -c 'import cv2, numpy; assert cv2.__version__ == "4.12.0"; assert numpy.__version__ == "1.24.4"; assert hasattr(cv2.aruco, "ArucoDetector")'
if dpkg-query -W -f='${Package}\n' | grep -E '^(lib)?xgc2-|ros-[a-z]+-xgc2-'; then
  echo "XGC2 packages leaked into build image" >&2
  exit 1
fi
