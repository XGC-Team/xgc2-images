#!/usr/bin/env bash
# FS150 Focal system Python SDK; image owns this implementation and robot baseline delegates to it.
set -euo pipefail
version=1.5.1
check() {
  PYTHONDONTWRITEBYTECODE=1 python3 -B - "$version" <<'PY'
import importlib.metadata
import sys
import threading
import zenoh

assert importlib.metadata.version('eclipse-zenoh') == sys.argv[1]
assert sys.version_info[:2] == (3, 8), sys.version
config = zenoh.Config.from_json5('{mode:"peer", scouting:{multicast:{enabled:false}, gossip:{enabled:false}}, listen:{endpoints:[]}, connect:{endpoints:[]}}')
event = threading.Event()
received = []
with zenoh.open(config) as session:
    def on_sample(sample):
        received.append(bytes(sample.payload))
        event.set()
    subscriber = session.declare_subscriber('xgc2/baseline/probe', on_sample)
    session.put('xgc2/baseline/probe', b'xgc2-zenoh-probe')
    assert event.wait(5) and received == [b'xgc2-zenoh-probe'], received
    subscriber.undeclare()
print('eclipse-zenoh %s: session and local pub/sub OK' % sys.argv[1])
PY
}
case "${1:-}" in
  check) check ;;
  apply)
    if check 2>/dev/null; then exit 0; fi
    tmp="$(mktemp -d)"
    trap 'rm -rf -- "$tmp"' EXIT
    # The public product's immutable dependency metadata selects the SDK version.
    curl -fsSL --retry 3 https://raw.githubusercontent.com/XGC-Team/xgc2-onboard-telemetry/4c24202c46a4d0bd836bb35fb5eae77d47decbe9/requirements-runtime.txt -o "$tmp/requirements-runtime.txt"
    echo '2e1db99fe83c9ac36a6bc38b046fa1f989dcfb05566f5ed5ba488ead337626b0  '"$tmp/requirements-runtime.txt" | sha256sum -c -
    [[ "$(cat "$tmp/requirements-runtime.txt")" == "eclipse-zenoh==$version" ]] || { echo 'Unexpected telemetry SDK dependency' >&2; exit 1; }
    case "$(dpkg --print-architecture)" in
      amd64)
        wheel=eclipse_zenoh-1.5.1-cp38-abi3-manylinux_2_17_x86_64.manylinux2014_x86_64.whl
        url=https://files.pythonhosted.org/packages/aa/4f/a9150d237f6ef71489395127d9c5ddd77fe5fb64864b92e0746eb04dc8a8/$wheel
        sha=76781bbfa61fdc1e9626a03202c7dd8fd103f34761dc7b94b5a2d99f5aae629e ;;
      arm64)
        wheel=eclipse_zenoh-1.5.1-cp38-abi3-manylinux_2_28_aarch64.whl
        url=https://files.pythonhosted.org/packages/a5/1d/9309130f890c6eb783703b5aa2c4718846900f810d123a1228c45416d871/$wheel
        sha=0f142a36241e50eb3b86f9c3b0149138d2d1d7b6dd2038589fe4c62e12e776ea ;;
      *) echo 'Unsupported Zenoh architecture' >&2; exit 1 ;;
    esac
    curl -fsSL --retry 3 "$url" -o "$tmp/$wheel"
    echo "$sha  $tmp/$wheel" | sha256sum -c -
    python3 -m pip install --no-input --no-deps --force-reinstall "$tmp/$wheel"
    check ;;
  *) echo 'usage: install-zenoh.sh check|apply' >&2; exit 2 ;;
esac
