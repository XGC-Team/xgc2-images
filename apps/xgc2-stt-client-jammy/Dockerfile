# syntax=docker/dockerfile:1.7
FROM ghcr.io/xgc-team/xgc2-images/xgc2-build-jammy-dev:1.0.0

LABEL org.opencontainers.image.title="XGC2 STT client Jammy"
LABEL org.opencontainers.image.description="Jammy STT desktop-client smoke image with GTK, PyAudio, websocket, and sounddevice Depends preinstalled."
LABEL org.opencontainers.image.source="https://github.com/XGC-Team/xgc2-images"

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY scripts/healthcheck.sh /usr/local/bin/xgc2-stt-client-healthcheck

RUN chmod +x /usr/local/bin/xgc2-stt-client-healthcheck \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      python3-gi \
      python3-gi-cairo \
      gir1.2-gtk-3.0 \
      gir1.2-ayatanaappindicator3-0.1 \
      gir1.2-notify-0.7 \
      python3-websocket \
      python3-pyaudio \
      python3-xlib \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work
CMD ["bash"]
