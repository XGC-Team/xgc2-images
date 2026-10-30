#!/usr/bin/env bash
set -euo pipefail
. /etc/os-release
test "${VERSION_CODENAME}" = "bionic"
/usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh
command -v g++ >/dev/null
command -v cmake >/dev/null
cmake --version | awk 'NR==1 { split($3, v, "."); exit !(v[1] > 3 || (v[1] == 3 && v[2] >= 16)) }'
command -v dpkg-buildpackage >/dev/null
command -v jq >/dev/null
command -v node >/dev/null
command -v pnpm >/dev/null
command -v uv >/dev/null
command -v rustc >/dev/null
command -v cargo >/dev/null
command -v go >/dev/null
command -v gh >/dev/null
command -v buf >/dev/null
command -v rg >/dev/null
dpkg-query -W libzmq3-dev libzmqpp-dev cmake fakeroot dpkg-dev \
  libeigen3-dev libgtest-dev libgflags-dev meson >/dev/null
python3 -c 'import yaml,numpy,casadi,deprecated; assert casadi.__version__.startswith("3.5.")'
test "$(/usr/bin/python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')" = "3.6"

acados_codegen_prefix="/opt/xgc2/acados-codegen-python"
test -x "${acados_codegen_prefix}/bin/python3.12"

check_acados_codegen_python() {
  local prefix="$1"
  "${prefix}/bin/python3.12" -I - "$prefix" <<'PY'
import sys

expected_prefix = sys.argv[1]
assert sys.executable == expected_prefix + "/bin/python3.12", sys.executable
assert sys.version_info[:3] == (3, 12, 12), sys.version_info
assert sys.prefix == expected_prefix, (sys.prefix, expected_prefix)
assert sys.base_prefix == expected_prefix, (sys.base_prefix, expected_prefix)
assert all(not path.startswith("/usr/local/share/uv/python") for path in sys.path), sys.path

from importlib.metadata import version
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
PY
}

check_acados_codegen_python "$acados_codegen_prefix"

# Exercise the same prefix from a different path. This is the relocation
# contract used when the acados package stages codegen-python into the deb.
relocated_root="$(mktemp -d)"
trap 'rm -rf -- "$relocated_root"' EXIT
relocated="${relocated_root}/codegen-python"
if ! cp -al "$acados_codegen_prefix" "$relocated" 2>/dev/null; then
  rm -rf "$relocated"
  cp -a "$acados_codegen_prefix" "$relocated"
fi
check_acados_codegen_python "$relocated"

node -v | grep -q '^v16'
if dpkg-query -W -f='${Package}\n' | grep -E '^(lib)?xgc2-|ros-[a-z]+-xgc2-'; then
  echo "XGC2 packages leaked into build image" >&2
  exit 1
fi
