#!/usr/bin/env bash
set -euo pipefail
. /etc/os-release
test "${VERSION_CODENAME}" = "focal"
/usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh
for package in ca-certificates init-system-helpers python3 systemd; do
  test "$(dpkg-query -W -f='${Status}' "$package")" = "install ok installed"
done
command -v systemctl >/dev/null
command -v deb-systemd-helper >/dev/null
command -v python3 >/dev/null
systemctl --version >/dev/null
if [[ "$(dpkg --print-architecture)" == "amd64" ]]; then
  test "$(dpkg-query -W -f='${Status}' qemu-user-static)" = "install ok installed"
  qemu-aarch64-static --version >/dev/null
  file /usr/bin/qemu-aarch64-static | grep -Eq "statically linked|static-pie linked"
fi
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
