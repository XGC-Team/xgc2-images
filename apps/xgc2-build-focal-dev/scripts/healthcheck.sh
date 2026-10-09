#!/usr/bin/env bash
set -euo pipefail
. /etc/os-release
test "${VERSION_CODENAME}" = "focal"
/usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh
command -v g++ >/dev/null
command -v cmake >/dev/null
command -v dpkg-buildpackage >/dev/null
command -v jq >/dev/null
command -v node >/dev/null
command -v pnpm >/dev/null
command -v uv >/dev/null
command -v rustc >/dev/null
command -v cargo >/dev/null
test "$(rustc --version | awk '{print $2}')" = "1.93.0"
test "$(cargo --version | awk '{print $2}')" = "1.93.0"
command -v go >/dev/null
command -v gh >/dev/null
command -v buf >/dev/null
command -v rg >/dev/null
dpkg-query -W libzmq3-dev libzmqpp-dev cmake fakeroot dpkg-dev \
  libeigen3-dev libgtest-dev libgflags-dev meson \
  libgrpc++-dev libprotobuf-dev protobuf-compiler-grpc libre2-dev \
  clang-format clang-tidy cppcheck >/dev/null
python3 -c 'import yaml,numpy,casadi,deprecated; assert casadi.__version__ == "3.7.2"'
meson --version | grep -q '^1\.3'
node -v | grep -q '^v22'
command -v skopeo >/dev/null
command -v bun >/dev/null
command -v yarn >/dev/null
if dpkg-query -W -f='${Package}\n' | grep -E '^(lib)?xgc2-|ros-[a-z]+-xgc2-'; then
  echo "XGC2 packages leaked into build image" >&2
  exit 1
fi

/usr/local/bin/xgc2-python-xrpc-healthcheck
test -d /opt/xgc2/npm-cache/_cacache

native_probe="$(mktemp)"
clang++-10 -std=c++2a -pthread $(pkg-config --cflags grpc++) -x c++ - \
  $(pkg-config --libs grpc++) -o "$native_probe" <<'CPP'
#include <stop_token>
#include <condition_variable>
#include <span>
#include <map>
#include <string_view>
#include <grpcpp/resource_quota.h>
#include <grpcpp/server_posix.h>
int main() {
  std::stop_source stop; std::stop_callback callback(stop.get_token(), [] {});
  std::mutex mutex; std::unique_lock<std::mutex> lock(mutex);
  std::condition_variable_any changed;
  changed.wait_until(lock, stop.get_token(), std::chrono::steady_clock::now(), [] { return true; });
  grpc::ResourceQuota quota; quota.Resize(1048576).SetMaxThreads(2);
  auto accepted_fd = &grpc::AddInsecureChannelFromFd;
  int data[1] = {0}; std::span<int> view(data); std::map<int, int> table;
  return !accepted_fd || view.size() != 1 || table.contains(0) || !std::string_view("xrpc").starts_with("x");
}
CPP
"$native_probe"
rm "$native_probe"
