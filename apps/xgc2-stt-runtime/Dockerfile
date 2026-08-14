# syntax=docker/dockerfile:1.7
FROM vllm/vllm-openai:v0.14.0@sha256:1d6866b87630d94f5e0cdae55ab5abb4ce0b03fcb84d9d10612f9d518d19d4fd

LABEL org.opencontainers.image.title="XGC2 STT runtime"
LABEL org.opencontainers.image.description="GPU STT runtime base with vLLM, sox, tini, qwen-asr, and frozen service Python deps."
LABEL org.opencontainers.image.source="https://github.com/XGC-Team/xgc2-images"

ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root
COPY lock/requirements-runtime.txt /tmp/stt-requirements-runtime.txt
COPY scripts/healthcheck.sh /usr/local/bin/xgc2-stt-runtime-healthcheck

RUN chmod +x /usr/local/bin/xgc2-stt-runtime-healthcheck \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      tini \
      sox \
      libsox-fmt-all \
 && rm -rf /var/lib/apt/lists/* \
 && python3 -m pip install --no-cache-dir -r /tmp/stt-requirements-runtime.txt "qwen-asr[vllm]==0.0.6" \
 && rm -f /tmp/stt-requirements-runtime.txt

WORKDIR /work
CMD ["bash"]
