#!/usr/bin/env bash
set -euo pipefail

# Build the Gazebo 11 rendering dependency with independent GPU-laser materials.
# The runtime image installs this library normally; no preload/interposer is used.
output_dir="${1:?output directory required}"
work_dir="${2:?build directory required}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version=11.15.1
mkdir -p "${output_dir}" "${work_dir}"
archive="${work_dir}/gazebo-${version}.tar.gz"
curl -fL --retry 3 \
  "https://github.com/gazebosim/gazebo-classic/archive/refs/tags/gazebo11_${version}.tar.gz" \
  -o "${archive}"
printf '%s  %s\n' \
  77a952971eabfd79e16d2582a355ee017a2e22cc369b68453323c0984b725126 \
  "${archive}" | sha256sum -c -
tar -xzf "${archive}" -C "${work_dir}"
source_dir="${work_dir}/gazebo-classic-gazebo11_${version}"
patch -d "${source_dir}" -p1 < "${script_dir}/gpu-laser-material.patch"
cmake -S "${source_dir}" -B "${work_dir}/build" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DENABLE_PROFILER=OFF \
  -DCMAKE_SKIP_RPATH=ON
cmake --build "${work_dir}/build" --target gazebo_rendering \
  --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-4}"
install -m 0755 \
  "${work_dir}/build/gazebo/rendering/libgazebo_rendering.so.${version}" \
  "${output_dir}/libgazebo_rendering.so.${version}"
strip --strip-unneeded "${output_dir}/libgazebo_rendering.so.${version}"
ln -s "libgazebo_rendering.so.${version}" "${output_dir}/libgazebo_rendering.so.11"
install -m 0644 "${source_dir}/COPYING" "${output_dir}/COPYING.gazebo"
