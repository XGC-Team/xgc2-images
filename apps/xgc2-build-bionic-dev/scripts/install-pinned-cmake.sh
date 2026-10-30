#!/usr/bin/env bash
# Install the pinned CMake binary for the Bionic build image. Ubuntu 18.04's
# distro cmake is 3.10, below the zenoh-c 1.8.0 floor (>= 3.16). This is an
# app-owned toolchain supply: no shared toolchains/generator edits, no product
# bootstrap. Binaries are the upstream Kitware release assets, SHA256-pinned.
set -euo pipefail

version="3.31.6"
arch="$(dpkg --print-architecture)"
case "${arch}" in
  amd64) cmake_arch="x86_64"; sha256="5a1133ff103c71eb5120e2cc3de922733e7d8a26a98ae716397e8676adb367bf" ;;
  arm64) cmake_arch="aarch64"; sha256="b4cc788d63112b2749b40627e719eb5d3b8ed8f00c36d77189f4019cfe64bc9e" ;;
  *) echo "unsupported architecture for pinned CMake: ${arch}" >&2; exit 1 ;;
esac

tarball="cmake-${version}-linux-${cmake_arch}.tar.gz"
url="https://github.com/Kitware/CMake/releases/download/v${version}/${tarball}"
scratch="$(mktemp -d)"
trap 'rm -rf -- "${scratch}"' EXIT

curl -fsSL --retry 5 --retry-delay 2 -o "${scratch}/${tarball}" "${url}"
printf '%s  %s\n' "${sha256}" "${scratch}/${tarball}" | sha256sum --check --quiet
mkdir -p "/opt/cmake-${version}"
tar -xzf "${scratch}/${tarball}" -C "/opt/cmake-${version}" --strip-components=1
for tool in cmake ctest cpack; do
  ln -sfn "/opt/cmake-${version}/bin/${tool}" "/usr/local/bin/${tool}"
done

installed="$(cmake --version | awk 'NR==1 { print $3 }')"
python3 - "${installed}" <<'PY'
import sys
have = tuple(int(part) for part in sys.argv[1].split("."))
if have < (3, 16):
    raise SystemExit(f"pinned cmake {sys.argv[1]} is below the required 3.16")
print("pinned cmake", sys.argv[1])
PY
