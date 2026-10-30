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
env -u LD_LIBRARY_PATH /usr/bin/python3 -c 'import yaml,numpy,casadi,deprecated; assert casadi.__version__.startswith("3.5.")'
test "$(env -u LD_LIBRARY_PATH /usr/bin/python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')" = "3.6"

acados_codegen_prefix="/opt/xgc2/acados-codegen-python"
test -x "${acados_codegen_prefix}/bin/python3"
test ! -L "${acados_codegen_prefix}/bin/python3"
test -x "${acados_codegen_prefix}/bin/python3.12"
test -f "${acados_codegen_prefix}/lib/libstdc++.so.6.0.30"
test -L "${acados_codegen_prefix}/lib/libstdc++.so.6"
test -f "${acados_codegen_prefix}/lib/libgcc_s.so.1"
test -L "${acados_codegen_prefix}/lib/libgcc_s.so"

check_acados_codegen_python() {
  local prefix="$1" order="$2"
  env -u LD_LIBRARY_PATH "${prefix}/bin/python3" -I - "$prefix" "$order" <<'PY'
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

check_acados_codegen_python "$acados_codegen_prefix" numpy-first
check_acados_codegen_python "$acados_codegen_prefix" casadi-first

# Entry contract with an inherited SDK/caller suffix: prepend only the private
# lib, preserve the suffix, and do not mutate the parent environment.
parent_ld="${LD_LIBRARY_PATH-__unset__}"
sentinel="/opt/xgc2/caller-sdk-lib"
env LD_LIBRARY_PATH="$sentinel" "${acados_codegen_prefix}/bin/python3" -I - \
  "$acados_codegen_prefix" "$sentinel" <<'PY'
import os
import sys
expected_prefix, sentinel = sys.argv[1], sys.argv[2]
assert sys.executable == expected_prefix + "/bin/python3.12", sys.executable
assert os.environ.get("LD_LIBRARY_PATH") == expected_prefix + "/lib:" + sentinel, os.environ.get("LD_LIBRARY_PATH")
PY
[[ "${LD_LIBRARY_PATH-__unset__}" == "$parent_ld" ]] || {
  echo "launcher mutated the parent LD_LIBRARY_PATH" >&2
  exit 1
}

# Exercise the same prefix from a different path. This is the relocation
# contract used when the acados package stages codegen-python into the deb.
relocated_root="$(mktemp -d)"
trap 'rm -rf -- "$relocated_root"' EXIT
relocated="${relocated_root}/codegen-python"
if ! cp -al "$acados_codegen_prefix" "$relocated" 2>/dev/null; then
  rm -rf "$relocated"
  cp -a "$acados_codegen_prefix" "$relocated"
fi
check_acados_codegen_python "$relocated" numpy-first
check_acados_codegen_python "$relocated" casadi-first

node -v | grep -q '^v16'
if dpkg-query -W -f='${Package}\n' | grep -E '^(lib)?xgc2-|ros-[a-z]+-xgc2-'; then
  echo "XGC2 packages leaked into build image" >&2
  exit 1
fi
