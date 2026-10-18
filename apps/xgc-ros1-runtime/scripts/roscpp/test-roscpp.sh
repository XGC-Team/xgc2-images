#!/usr/bin/env bash
set -euo pipefail

# Real SDK socket/lifetime regressions against the explicitly selected library.
# The counter preload is restricted to each test process, never a runtime image.
library_dir="${1:?library directory required}"
output_dir="${2:?test output directory required}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
library_dir="$(cd "${library_dir}" && pwd)"
[[ -f "${library_dir}/libroscpp.so" ]]
library_path="$(readlink -f "${library_dir}/libroscpp.so")"
mkdir -p "${output_dir}"
output_dir="$(cd "${output_dir}" && pwd)"

set +u
source /opt/ros/noetic/setup.bash
set -u

g++ -std=c++14 -O2 -Wall -Wextra -Werror -fPIC -shared \
  "${script_dir}/tcp_counter.cpp" -ldl -o "${output_dir}/tcp-counter.so"
g++ -std=c++14 -O2 -Wall -Wextra -Werror -UNDEBUG \
  -I/opt/ros/noetic/include \
  "${script_dir}/phase_drain_test.cpp" \
  -L"${library_dir}" -L/opt/ros/noetic/lib -lroscpp -ldl -pthread \
  -o "${output_dir}/phase-drain-test"

for case in full partial eagain close chain external immediate io-callback \
  lifetime foreign-pollset udp nested-immediate nested-pressure cross-immediate; do
  timeout 25s env \
    LD_LIBRARY_PATH="${library_dir}:/opt/ros/noetic/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    LD_PRELOAD="${output_dir}/tcp-counter.so" \
    "${output_dir}/phase-drain-test" "${case}" nested \
      "${output_dir}/${case}-maps.txt" \
      > "${output_dir}/${case}.jsonl" 2> "${output_dir}/${case}.log"
  awk -v expected="${library_path}" '$NF == expected { found = 1 } END { exit !found }' \
    "${output_dir}/${case}-maps.txt"
done
