#!/usr/bin/env bash
set -euo pipefail

# Build the complete ROS 1 roscpp library with the phase-drain patch.
# The runtime image installs this library normally; no preload/interposer is used.
output_dir="${1:?output directory required}"
work_dir="${2:?build directory required}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version=1.17.4
mkdir -p "${output_dir}" "${work_dir}"
archive="${work_dir}/ros_comm-${version}.tar.gz"
if [[ ! -f "${archive}" ]]; then
  curl -fL --retry 3 \
    "https://codeload.github.com/ros/ros_comm/tar.gz/refs/tags/${version}" \
    -o "${archive}"
fi
printf '%s  %s\n' \
  180c5bf2810321a6a3c76f9c74fc35b7dd8bccd2d3af5ebd7dca6b416df2bd93 \
  "${archive}" | sha256sum -c -
tar -xzf "${archive}" -C "${work_dir}"
source_dir="${work_dir}/ros_comm-${version}"
patch --batch --fuzz=0 -d "${source_dir}" -p1 < "${script_dir}/deferred-tcp-write.patch"
set +u
source /opt/ros/noetic/setup.bash
set -u
cmake -S "${source_dir}/clients/roscpp" -B "${work_dir}/build" \
  -DCMAKE_BUILD_TYPE=Release -DCATKIN_ENABLE_TESTING=OFF \
  -DPYTHON_EXECUTABLE=/usr/bin/python3 -DCMAKE_SKIP_RPATH=ON
cmake --build "${work_dir}/build" --target roscpp \
  --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-4}"
install -m 0755 "${work_dir}/build/devel/lib/libroscpp.so" \
  "${output_dir}/libroscpp.so"
strip --strip-unneeded "${output_dir}/libroscpp.so"
readelf -d "${output_dir}/libroscpp.so" | grep -Fq 'Library soname: [libroscpp.so]'
! readelf -d "${output_dir}/libroscpp.so" | grep -Eq '\((RPATH|RUNPATH)\)'
# ros_comm has per-source BSD notices, not a top-level roscpp COPYING file.
# Retain the official package's complete copyright/license notices from the SDK.
install -m 0644 /usr/share/doc/ros-noetic-roscpp/copyright \
  "${output_dir}/COPYING.roscpp"
