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
  libffmpeg-nvenc-dev nlohmann-json3-dev libglfw3-dev libglm-dev >/dev/null
# Compile and link the GPU sensor headers without requiring a display or GPU.
gpu_probe="$(mktemp)"
trap 'rm -f "${gpu_probe}"' EXIT
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
python3 -c 'import cv2, numpy; assert cv2.__version__ == "4.12.0"; assert numpy.__version__ == "1.24.4"; assert hasattr(cv2.aruco, "ArucoDetector")'
if dpkg-query -W -f='${Package}\n' | grep -E '^(lib)?xgc2-|ros-[a-z]+-xgc2-'; then
  echo "XGC2 packages leaked into build image" >&2
  exit 1
fi
