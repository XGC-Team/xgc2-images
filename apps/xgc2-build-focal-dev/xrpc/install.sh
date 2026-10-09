#!/usr/bin/env bash
set -euo pipefail
mode="${1:?builder or runtime}"
root="$(cd "$(dirname "$0")" && pwd)"
test "$mode" = builder || test "$mode" = runtime
python3 -c 'import sys; assert sys.version_info >= (3,8)'
install -d /opt/xgc2/python-xrpc-wheels
python3 -m pip download --only-binary=:all: --require-hashes \
  -r "$root/python-focal.lock" -d /opt/xgc2/python-xrpc-wheels
pip_args=(--no-index --ignore-installed --only-binary=:all: --require-hashes)
if [[ "$(. /etc/os-release; echo "$VERSION_CODENAME")" = noble ]]; then
  pip_args+=(--break-system-packages)
fi
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
