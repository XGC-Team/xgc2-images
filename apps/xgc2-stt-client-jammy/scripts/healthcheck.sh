#!/usr/bin/env bash
set -euo pipefail
. /etc/os-release
test "${VERSION_CODENAME}" = "jammy"
command -v xvfb-run >/dev/null
python3 - <<'PY'
import gi
import pyaudio
import sounddevice
import websocket
import Xlib
PY
