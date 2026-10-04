#!/usr/bin/env bash
set -euo pipefail

# Ordinary upstream rosbag/storage, with only the tested pure-Write mirror guards.
output_dir="${1:?output directory required}"
work_dir="${2:?build directory required}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
commit=25d371664e34ec9d26ee331434de9a38c412c890 # ros_comm 1.17.4
mkdir -p "${output_dir}/lib/rosbag" "${output_dir}/include/rosbag" "${work_dir}"
archive="${work_dir}/ros_comm-${commit}.tar.gz"
curl -fL --retry 3 "https://github.com/ros/ros_comm/archive/${commit}.tar.gz" -o "${archive}"
tar -xzf "${archive}" -C "${work_dir}" \
  "ros_comm-${commit}/tools/rosbag" "ros_comm-${commit}/tools/rosbag_storage"
source_dir="${work_dir}/ros_comm-${commit}"
patch --batch --fuzz=0 -d "${source_dir}" -p1 < "${script_dir}/pure-write-mirror.patch"
workspace="${work_dir}/workspace"
mkdir -p "${workspace}/src"
ln -s "${source_dir}/tools/rosbag" "${workspace}/src/rosbag"
ln -s "${source_dir}/tools/rosbag_storage" "${workspace}/src/rosbag_storage"
ln -s /opt/ros/noetic/share/catkin/cmake/toplevel.cmake "${workspace}/src/CMakeLists.txt"
set +u
source /opt/ros/noetic/setup.bash
set -u
# record depends on librosbag: recorder.cpp instantiates the patched Bag templates.
catkin_make -C "${workspace}" -j1 -l1 record rosbag_default_encryption_plugins \
  -DCMAKE_BUILD_TYPE=Release -DCATKIN_ENABLE_TESTING=OFF
install -m 0755 "${workspace}/devel/lib/rosbag/record" "${output_dir}/lib/rosbag/record"
for library in librosbag.so librosbag_storage.so librosbag_default_encryption_plugins.so; do
  install -m 0644 "${workspace}/devel/lib/${library}" "${output_dir}/lib/${library}"
done
install -m 0644 "${source_dir}/tools/rosbag_storage/include/rosbag/bag.h" "${output_dir}/include/rosbag/bag.h"
sed -n '1,32p' "${source_dir}/tools/rosbag_storage/include/rosbag/bag.h" > "${output_dir}/COPYING.rosbag"
printf 'ros/ros_comm 1.17.4\ncommit %s\nsource https://github.com/ros/ros_comm\n' "${commit}" > "${output_dir}/SOURCE.rosbag"
