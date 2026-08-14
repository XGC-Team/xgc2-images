# syntax=docker/dockerfile:1.7
FROM vllm/vllm-openai:v0.14.0@sha256:1d6866b87630d94f5e0cdae55ab5abb4ce0b03fcb84d9d10612f9d518d19d4fd

LABEL org.opencontainers.image.title="XGC2 STT runtime"
LABEL org.opencontainers.image.description="GPU STT runtime base with vLLM, sox, tini, qwen-asr, and service Python extras."
LABEL org.opencontainers.image.source="https://github.com/XGC-Team/xgc2-images"

ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root
COPY scripts/healthcheck.sh /usr/local/bin/xgc2-stt-runtime-healthcheck

# Do not pip-install the service uv.lock here: its numpy pin conflicts with
# numba from qwen-asr[vllm]. Let vLLM keep its numpy; add only the extra
# service libraries that the vLLM image does not already provide.
RUN chmod +x /usr/local/bin/xgc2-stt-runtime-healthcheck \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      tini \
      sox \
      libsox-fmt-all \
 && rm -rf /var/lib/apt/lists/* \
 && python3 -m pip install --no-cache-dir --ignore-installed \
      "qwen-asr[vllm]==0.0.6" \
      "av>=16,<19" \
      "nvidia-ml-py>=13,<14" \
      "opencc-python-reimplemented>=0.1.7,<0.2" \
      "pydantic-settings==2.15.0" \
      "python-multipart==0.0.32"

WORKDIR /work
CMD ["bash"]
