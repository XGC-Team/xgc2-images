#!/usr/bin/env bash
set -euo pipefail
mode="${1:?builder or runtime}"
root="$(cd "$(dirname "$0")" && pwd)"
test "$mode" = builder || test "$mode" = runtime
python3 -c 'import sys; assert sys.version_info >= (3,8)'
pip_platform_args=()
if [[ "$(. /etc/os-release; echo "$VERSION_CODENAME")" = noble ]]; then
  pip_platform_args+=(--break-system-packages)
fi
# Focal's archive pip predates the manylinux tags of supported arm64 wheels.
curl -fsSL --retry 5 https://files.pythonhosted.org/packages/c9/bc/b7db44f5f39f9d0494071bddae6880eb645970366d0a200022a1a93d57f5/pip-25.0.1-py3-none-any.whl -o /tmp/pip-25.0.1-py3-none-any.whl
echo 'c46efd13b6aa8279f33f2864459c8ce587ea6a1a59ee20de055868d8f7688f7f  /tmp/pip-25.0.1-py3-none-any.whl' | sha256sum -c -
python3 -m pip install --no-index --ignore-installed "${pip_platform_args[@]}" /tmp/pip-25.0.1-py3-none-any.whl
rm /tmp/pip-25.0.1-py3-none-any.whl
install -d /opt/xgc2/python-xrpc-wheels
python3 -m pip download --only-binary=:all: --require-hashes \
  -r "$root/python-focal.lock" -d /opt/xgc2/python-xrpc-wheels
mapfile -t replaced < <(python3 - "$root/python-focal.lock" <<'PY'
import re, sys
from importlib.metadata import distributions
names = {line.split('==')[0].lower().replace('_', '-')
         for line in open(sys.argv[1]) if re.match(r'^[a-z][a-z0-9-]*==', line)}
for distribution in distributions():
    name = distribution.metadata['Name'].lower().replace('_', '-')
    if name in names and str(distribution.locate_file('')).startswith('/usr/local/'):
        print(name)
PY
)
if (( ${#replaced[@]} )); then
  python3 -m pip uninstall -y "${pip_platform_args[@]}" "${replaced[@]}"
fi
pip_args=(--no-index --ignore-installed --only-binary=:all: --require-hashes "${pip_platform_args[@]}")
python3 -m pip install "${pip_args[@]}" \
  --find-links /opt/xgc2/python-xrpc-wheels -r "$root/python-focal.lock"
install -m 0644 "$root/python-focal.lock" /opt/xgc2/python-xrpc.lock
install -m 0755 "$root/healthcheck.py" /usr/local/bin/xgc2-python-xrpc-healthcheck
/usr/local/bin/xgc2-python-xrpc-healthcheck
if [[ "$mode" = builder ]]; then
  curl -fsSL --retry 5 https://registry.npmjs.org/ws/-/ws-8.22.0.tgz -o /tmp/xgc2-ws-8.22.0.tgz
  echo 'ca9b3798b2e11ce8fac6713f50ef0501aa12b09b330623c1dc409dff94e7abc8  /tmp/xgc2-ws-8.22.0.tgz' | sha256sum -c -
  npm cache add /tmp/xgc2-ws-8.22.0.tgz --cache /opt/xgc2/npm-cache --ignore-scripts
  chmod -R a+rX /opt/xgc2/npm-cache /opt/xgc2/python-xrpc-wheels
  rm /tmp/xgc2-ws-8.22.0.tgz
fi
