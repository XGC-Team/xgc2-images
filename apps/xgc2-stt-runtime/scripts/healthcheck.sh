#!/usr/bin/env bash
set -euo pipefail
command -v sox >/dev/null
command -v tini >/dev/null
command -v curl >/dev/null
python3 - <<'PY'
import importlib.metadata
import av
import fastapi
import huggingface_hub

importlib.metadata.version("qwen-asr")
importlib.metadata.version("vllm")
PY
