#!/usr/bin/env bash
set -euo pipefail
. /etc/os-release
test "${VERSION_CODENAME}" = "noble"
test -x /opt/xgc2-stt/venv/bin/python
command -v ruff >/dev/null
command -v pytest >/dev/null
command -v node >/dev/null
command -v npm >/dev/null
test -d /opt/xgc2-stt/web/node_modules/vite
test -d /opt/xgc2-stt/web/node_modules/vitest
python3 - <<'PY'
import av
import fastapi
import gi
import pyaudio
import pytest
import ruff
import sounddevice
import websocket
import Xlib
PY
node -v | grep -q '^v22'
