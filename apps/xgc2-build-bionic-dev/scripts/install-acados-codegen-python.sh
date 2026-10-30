#!/usr/bin/env bash
# Build the private acados code-generation Python for Bionic.
#
# The build image already has the verified uv-managed CPython 3.12.12. Copy it
# to a relocatable prefix and install only the pinned native wheels from the
# app-owned lock. This runs during the Docker build; the host and the system
# Python 3.6 used by ROS are never touched.
set -euo pipefail

readonly python_version="3.12.12"
readonly destination="/opt/xgc2/acados-codegen-python"
readonly source_root="/usr/local/share/uv/python"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lock="${ACADOS_CODEGEN_WHEEL_LOCK:-}"
if [[ -z "$lock" ]]; then
  if [[ -r "${script_dir}/acados-codegen-wheels.lock" ]]; then
    lock="${script_dir}/acados-codegen-wheels.lock"
  else
    lock="${script_dir}/../lock/acados-codegen-wheels.lock"
  fi
fi

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
[[ -r "$lock" ]] || fail "missing wheel lock at ${lock}"
command -v uv >/dev/null 2>&1 || fail "uv is required to install the private codegen wheels"

source_version="$("${source_prefix}/bin/python3.12" -I -c 'import platform; print(platform.python_version())')"
[[ "$source_version" == "$python_version" ]] \
  || fail "uv Python is ${source_version}, required ${python_version}"

# Copy, do not link: the acados package stages this prefix into the deb.
rm -rf "$destination"
install -d -m 0755 "$(dirname "$destination")"
cp -a "$source_prefix" "$destination"
rm -rf "${destination}/.temp"
chmod -R a+rX "$destination"

if find "$destination" -type l -lname "${source_prefix}/*" -print -quit | grep -q .; then
  fail "copied interpreter still contains absolute symlinks into ${source_prefix}"
fi

scratch="$(mktemp -d)"
relocated_root="$(mktemp -d)"
trap 'rm -rf -- "$scratch" "$relocated_root"' EXIT

# Prove the copied interpreter works from a different path before adding wheels.
relocated="${relocated_root}/codegen-python"
if ! cp -al "$destination" "$relocated" 2>/dev/null; then
  rm -rf "$relocated"
  cp -a "$destination" "$relocated"
fi
"${relocated}/bin/python3.12" -I - "$relocated" <<'PY'
import sys
expected = sys.argv[1]
assert sys.prefix == expected, (sys.prefix, expected)
assert sys.base_prefix == expected, (sys.base_prefix, expected)
PY
rm -rf "$relocated"

wheel_count=0
while read -r wheel_arch package filename url sha; do
  [[ -n "${wheel_arch:-}" && "$wheel_arch" != \#* ]] || continue
  [[ "$wheel_arch" == "$(dpkg --print-architecture)" ]] || continue
  [[ "$url" == https://*/*.whl ]] || fail "non-wheel URL for ${package}: ${url}"
  wheel="${scratch}/${filename}"
  echo "download ${package} ${filename}"
  for attempt in 1 2 3 4 5; do
    if curl -fsSL --connect-timeout 30 --max-time 300 -o "$wheel" "$url"; then
      break
    fi
    rm -f "$wheel"
    [[ "$attempt" -lt 5 ]] || fail "cannot download ${package} after ${attempt} attempts: ${url}"
    sleep $((attempt * 2))
  done
  printf '%s  %s\n' "$sha" "$wheel" | sha256sum -c --quiet -
  wheel_count=$((wheel_count + 1))
done <"$lock"

[[ "$wheel_count" -eq 7 ]] || fail "expected 7 pinned wheels, found ${wheel_count}"

uv pip install --python "${destination}/bin/python3.12" \
  --no-cache --no-index --no-deps --only-binary=:all: --break-system-packages \
  "$scratch"/*.whl

"${destination}/bin/python3.12" -I - "$destination" <<'PY'
import sys
from importlib.metadata import version

expected_prefix = sys.argv[1]
assert sys.version_info[:3] == (3, 12, 12), sys.version_info
assert sys.prefix == expected_prefix, (sys.prefix, expected_prefix)
assert sys.base_prefix == expected_prefix, (sys.base_prefix, expected_prefix)

import casadi
import Cython
import deprecated
import numpy
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
print("acados codegen Python", sys.version.split()[0], "at", sys.prefix)
for name, want in expected.items():
    print(f"  {name} {version(name)}")
PY
