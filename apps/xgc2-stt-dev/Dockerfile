# syntax=docker/dockerfile:1.7
FROM ghcr.io/xgc-team/xgc2-images/xgc2-build-noble-dev:1.0.0

LABEL org.opencontainers.image.title="XGC2 STT CI"
LABEL org.opencontainers.image.description="Noble STT product CI image with frozen Python extras, WebUI node_modules, and desktop-client APT Depends."
LABEL org.opencontainers.image.source="https://github.com/XGC-Team/xgc2-images"

ENV DEBIAN_FRONTEND=noninteractive
ENV NODE_PATH=/opt/xgc2-stt/web/node_modules
ENV PATH="/opt/xgc2-stt/web/node_modules/.bin:${PATH}"
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY lock/requirements-dev.txt /tmp/stt-requirements-dev.txt
COPY lock/web/ /tmp/stt-web/
COPY scripts/healthcheck.sh /usr/local/bin/xgc2-stt-dev-healthcheck

RUN chmod +x /usr/local/bin/xgc2-stt-dev-healthcheck \
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
 && rm -rf /var/lib/apt/lists/* \
 && uv pip install --system --no-cache-dir -r /tmp/stt-requirements-dev.txt \
 && install -d /opt/xgc2-stt/web \
 && cp /tmp/stt-web/package.json /tmp/stt-web/package-lock.json /tmp/stt-web/.npmrc /opt/xgc2-stt/web/ \
 && npm --prefix /opt/xgc2-stt/web ci --omit=dev=false \
 && rm -rf /tmp/stt-requirements-dev.txt /tmp/stt-web /root/.npm /root/.cache

WORKDIR /work
CMD ["bash"]
