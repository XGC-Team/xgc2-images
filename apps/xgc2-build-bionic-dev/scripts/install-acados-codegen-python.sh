#!/usr/bin/env bash
# Build the private acados code-generation Python for Bionic.
#
# The build image already has the verified uv-managed CPython 3.12.12. Copy it
# to a relocatable prefix, add the small conda-forge GCC runtime needed by the
# official CasADi aarch64 wheel, and install only the pinned native wheels from
# the app-owned lock. This runs during the Docker build; the host and the system
# Python 3.6 used by ROS are never touched.
set -euo pipefail

readonly python_version="3.12.12"
readonly destination="/opt/xgc2/acados-codegen-python"
readonly source_root="/usr/local/share/uv/python"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
resolve_lock() {
  local name="$1" override="$2"
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
  elif [[ -r "${script_dir}/${name}" ]]; then
    printf '%s\n' "${script_dir}/${name}"
  else
    printf '%s\n' "${script_dir}/../lock/${name}"
  fi
}
wheel_lock="$(resolve_lock acados-codegen-wheels.lock "${ACADOS_CODEGEN_WHEEL_LOCK:-}")"
runtime_lock="$(resolve_lock acados-codegen-runtime.lock "${ACADOS_CODEGEN_RUNTIME_LOCK:-}")"

fail() {
  echo "acados-codegen-python: $*" >&2
  exit 1
}

case "$(dpkg --print-architecture)" in
  amd64) uv_arch="x86_64" ;;
  arm64) uv_arch="aarch64" ;;
  *) fail "unsupported architecture: $(dpkg --print-architecture)" ;;
esac

source_prefix="${source_root}/cpython-${python_version}-linux-${uv_arch}-gnu"
[[ -x "${source_prefix}/bin/python3.12" ]] || fail "missing verified uv Python at ${source_prefix}"
[[ -r "$wheel_lock" ]] || fail "missing wheel lock at ${wheel_lock}"
[[ -r "$runtime_lock" ]] || fail "missing runtime lock at ${runtime_lock}"
for tool in uv unzip zstd tar readelf sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing build tool: ${tool}"
done

source_version="$("${source_prefix}/bin/python3" -I -c 'import platform; print(platform.python_version())')"
[[ "$source_version" == "$python_version" ]] \
  || fail "uv Python is ${source_version}, required ${python_version}"

# Copy, do not link: the acados package stages this prefix into the deb.
rm -rf "$destination"
install -d -m 0755 "$(dirname "$destination")"
cp -a "$source_prefix" "$destination"
rm -rf "${destination}/.temp"

absolute_link="$(find "$destination" -type l -lname "${source_prefix}/*" -print -quit)"
[[ -z "$absolute_link" ]] || fail "copied interpreter still contains an absolute symlink: ${absolute_link}"

scratch="$(mktemp -d)"
relocated_root="$(mktemp -d)"
trap 'rm -rf -- "$scratch" "$relocated_root"' EXIT

download() {
  local url="$1" output="$2" package="$3"
  local attempt
  for attempt in 1 2 3 4 5; do
    if curl -fsSL --connect-timeout 30 --max-time 300 -o "$output" "$url"; then
      return 0
    fi
    rm -f "$output"
    [[ "$attempt" -lt 5 ]] || fail "cannot download ${package} after ${attempt} attempts: ${url}"
    sleep $((attempt * 2))
  done
}

# Install only the private C++ runtime needed by the official CasADi aarch64
# wheel. No conda environment, package manager, system loader path or system
# compiler payload is created.
runtime_count=0
while read -r wheel_arch package version filename url sha; do
  [[ -n "${wheel_arch:-}" && "$wheel_arch" != \#* ]] || continue
  [[ "$wheel_arch" == "$(dpkg --print-architecture)" ]] || continue
  [[ "$url" == https://*/*.conda ]] || fail "non-archive URL for ${package}: ${url}"

  archive="${scratch}/${filename}"
  echo "download ${package} ${version} ${filename}"
  download "$url" "$archive" "$package"
  printf '%s  %s\n' "$sha" "$archive" | sha256sum -c --quiet -

  pkg_member="$(unzip -Z1 "$archive" | awk '/^pkg-.*\.tar\.zst$/ {print; exit}')"
  info_member="$(unzip -Z1 "$archive" | awk '/^info-.*\.tar\.zst$/ {print; exit}')"
  [[ -n "$pkg_member" ]] || fail "missing pkg archive in ${filename}"
  [[ -n "$info_member" ]] || fail "missing info archive in ${filename}"

  pkg_tar="${scratch}/${package}-pkg.tar.zst"
  info_tar="${scratch}/${package}-info.tar.zst"
  unzip -p "$archive" "$pkg_member" >"$pkg_tar"
  unzip -p "$archive" "$info_member" >"$info_tar"

  license_dir="${destination}/lib/licenses/${package}"
  install -d -m 0755 "$license_dir"

  case "$package" in
    libstdcxx-ng)
      tar -I zstd -xOf "$pkg_tar" lib/libstdc++.so.6.0.30 >"${destination}/lib/libstdc++.so.6.0.30"
      chmod 0755 "${destination}/lib/libstdc++.so.6.0.30"
      ln -sfn libstdc++.so.6.0.30 "${destination}/lib/libstdc++.so.6"
      license_member="share/licenses/libstdc++/RUNTIME.LIBRARY.EXCEPTION"
      ;;
    libgcc-ng)
      tar -I zstd -xOf "$pkg_tar" lib/libgcc_s.so.1 >"${destination}/lib/libgcc_s.so.1"
      chmod 0755 "${destination}/lib/libgcc_s.so.1"
      ln -sfn libgcc_s.so.1 "${destination}/lib/libgcc_s.so"
      license_member="share/licenses/gcc-libs/RUNTIME.LIBRARY.EXCEPTION"
      ;;
    *)
      fail "unexpected runtime package: ${package}"
      ;;
  esac

  pkg_files="${scratch}/${package}-files.txt"
  tar -I zstd -tf "$pkg_tar" >"$pkg_files"
  grep -qx "$license_member" "$pkg_files" \
    || fail "missing ${license_member} in ${filename}"
  tar -I zstd -xOf "$pkg_tar" "$license_member" >"${license_dir}/RUNTIME.LIBRARY.EXCEPTION"
  tar -I zstd -xOf "$info_tar" info/about.json >"${license_dir}/about.json"
  tar -I zstd -xOf "$info_tar" info/index.json >"${license_dir}/index.json"

  {
    echo "package=${package}"
    echo "version=${version}"
    echo "archive=${filename}"
    echo "url=${url}"
    echo "sha256=${sha}"
    echo "license=${license_member}"
    echo "source=conda-forge"
  } >"${license_dir}/PROVENANCE.txt"

  runtime_count=$((runtime_count + 1))
done <"$runtime_lock"

[[ "$runtime_count" -eq 2 ]] || fail "expected 2 pinned runtime archives, found ${runtime_count}"
cp "$runtime_lock" "${destination}/lib/licenses/acados-codegen-runtime.lock"

libstdcxx_real="${destination}/lib/libstdc++.so.6.0.30"
libstdcxx_link="${destination}/lib/libstdc++.so.6"
libgcc_real="${destination}/lib/libgcc_s.so.1"
libgcc_link="${destination}/lib/libgcc_s.so"
[[ -f "$libstdcxx_real" && -L "$libstdcxx_link" ]] || fail "invalid private libstdc++ payload"
[[ -f "$libgcc_real" && -L "$libgcc_link" ]] || fail "invalid private libgcc payload"
[[ "$(readlink "$libstdcxx_link")" == "libstdc++.so.6.0.30" ]] || fail "non-relative libstdc++ link"
[[ "$(readlink "$libgcc_link")" == "libgcc_s.so.1" ]] || fail "non-relative libgcc link"
readelf -d "$libstdcxx_real" >"${scratch}/libstdcxx.dynamic"
readelf -d "$libgcc_real" >"${scratch}/libgcc.dynamic"
readelf -Ws "$libstdcxx_real" >"${scratch}/libstdcxx.symbols"
readelf --version-info "$libstdcxx_real" >"${scratch}/libstdcxx.versions"
grep -q 'SONAME.*\[libstdc++.so.6\]' "${scratch}/libstdcxx.dynamic" || fail "libstdc++ SONAME mismatch"
grep -q 'SONAME.*\[libgcc_s.so.1\]' "${scratch}/libgcc.dynamic" || fail "libgcc SONAME mismatch"
grep -q '_ZNSt7__cxx1118basic_stringstreamIcSt11char_traitsIcESaIcEEC1Ev' "${scratch}/libstdcxx.symbols" \
  || fail "private libstdc++ lacks the required stringstream constructor"
grep -q 'GLIBCXX_3.4.26' "${scratch}/libstdcxx.versions" \
  || fail "private libstdc++ lacks GLIBCXX_3.4.26"
max_glibc="$(grep -oE 'GLIBC_[0-9.]+' "${scratch}/libstdcxx.versions" | sed 's/^GLIBC_//' | sort -Vu | tail -1)"
[[ -n "$max_glibc" ]] || fail "private libstdc++ has no GLIBC version requirements"
dpkg --compare-versions "$max_glibc" le "2.17" \
  || fail "private libstdc++ requires GLIBC_${max_glibc}, newer than Bionic-era 2.17"

# Replace uv's python3 symlink with the SDK-owned entry. The launcher changes
# only its child environment; bin/python3.12 itself is unchanged.
python312_sha="$(sha256sum "${destination}/bin/python3.12" | awk '{print $1}')"
rm -f "${destination}/bin/python3"
cat >"${destination}/bin/python3" <<'SH'
#!/bin/sh
set -eu
prefix=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)
LD_LIBRARY_PATH="$prefix/lib"
export LD_LIBRARY_PATH
exec "$prefix/bin/python3.12" "$@"
SH
chmod 0755 "${destination}/bin/python3"
[[ ! -L "${destination}/bin/python3" ]] || fail "private python3 entry is still a symlink"
[[ "$(sha256sum "${destination}/bin/python3.12" | awk '{print $1}')" == "$python312_sha" ]] \
  || fail "bin/python3.12 was modified while installing the entry"
"${destination}/bin/python3" -I -c 'import os, sys; assert sys.argv[1] == os.environ.get("LD_LIBRARY_PATH")' \
  "${destination}/lib"

wheel_count=0
while read -r wheel_arch package filename url sha; do
  [[ -n "${wheel_arch:-}" && "$wheel_arch" != \#* ]] || continue
  [[ "$wheel_arch" == "$(dpkg --print-architecture)" ]] || continue
  [[ "$url" == https://*/*.whl ]] || fail "non-wheel URL for ${package}: ${url}"
  wheel="${scratch}/${filename}"
  echo "download ${package} ${filename}"
  download "$url" "$wheel" "$package"
  printf '%s  %s\n' "$sha" "$wheel" | sha256sum -c --quiet -
  wheel_count=$((wheel_count + 1))
done <"$wheel_lock"

[[ "$wheel_count" -eq 7 ]] || fail "expected 7 pinned wheels, found ${wheel_count}"

uv pip install --python "${destination}/bin/python3" \
  --no-cache --no-index --no-deps --only-binary=:all: --break-system-packages \
  "$scratch"/*.whl

check_codegen() {
  local prefix="$1" order="$2"
  "${prefix}/bin/python3" -I - "$prefix" "$order" <<'PY'
import os
import sys
from importlib.metadata import version

expected_prefix, order = sys.argv[1], sys.argv[2]
assert sys.executable == expected_prefix + "/bin/python3.12", sys.executable
assert sys.version_info[:3] == (3, 12, 12), sys.version_info
assert sys.prefix == expected_prefix, (sys.prefix, expected_prefix)
assert sys.base_prefix == expected_prefix, (sys.base_prefix, expected_prefix)
assert os.environ.get("LD_LIBRARY_PATH") == expected_prefix + "/lib", os.environ.get("LD_LIBRARY_PATH")
assert all(not path.startswith("/usr/local/share/uv/python") for path in sys.path), sys.path

if order == "numpy-first":
    import numpy
    import casadi
elif order == "casadi-first":
    import casadi
    import numpy
else:
    raise AssertionError(order)

import Cython
import deprecated
import scipy
import typing_extensions
import wrapt

expected = {
    "casadi": "3.7.2",
    "numpy": "1.26.4",
    "scipy": "1.11.4",
    "Deprecated": "1.2.14",
    "wrapt": "1.16.0",
    "typing_extensions": "4.12.2",
    "Cython": "3.0.12",
}
for name, want in expected.items():
    have = version(name)
    assert have == want, (name, have, want)

x = casadi.MX.sym("x")
f = casadi.Function("f", [x], [x * x])
assert float(f(2.0)) == 4.0, f(2.0)
PY
}

check_codegen "$destination" numpy-first
check_codegen "$destination" casadi-first

# Prove the full prefix (interpreter, private runtime, launcher and wheels)
# works from a different path.
relocated="${relocated_root}/codegen-python"
cp -a "$destination" "$relocated"
check_codegen "$relocated" numpy-first
check_codegen "$relocated" casadi-first
rm -rf "$relocated"

chmod -R a+rX "$destination"

"${destination}/bin/python3" -I - "$destination" <<'PY'
import sys
from importlib.metadata import version

expected_prefix = sys.argv[1]
assert sys.version_info[:3] == (3, 12, 12), sys.version_info
assert sys.prefix == expected_prefix, (sys.prefix, expected_prefix)
assert sys.base_prefix == expected_prefix, (sys.base_prefix, expected_prefix)
for name, want in {
    "casadi": "3.7.2",
    "numpy": "1.26.4",
    "scipy": "1.11.4",
    "Deprecated": "1.2.14",
    "wrapt": "1.16.0",
    "typing_extensions": "4.12.2",
    "Cython": "3.0.12",
}.items():
    assert version(name) == want, (name, version(name), want)
print("acados codegen Python", sys.version.split()[0], "at", sys.prefix)
for name in ("casadi", "numpy", "scipy", "Deprecated", "wrapt", "typing_extensions", "Cython"):
    print(f"  {name} {version(name)}")
PY
