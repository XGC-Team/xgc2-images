FROM golang:1.26-bookworm@sha256:db25d241820546be7b96953eea8d3e6bd15d413d59d00a75b68b74dfb5e2ecd2 AS execution-runner-build

WORKDIR /src
COPY scripts/xgc-process-runner.go /src/xgc-process-runner.go
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/xgc-process-runner /src/xgc-process-runner.go

FROM ghcr.io/lxk36/xgc2-app-store/xgc-ros1-runtime:1.2.3@sha256:01bb09579865965b441073618acce335480f0dbb3c029e967e7d42585be198a9

LABEL org.opencontainers.image.title="XGC2 ROS1 Central Simulation"
LABEL org.opencontainers.image.description="Reproducible ROS Noetic central simulation runtime for XGC2 FS150, Scout Mini, and Mecanum UGV fleets."
LABEL org.opencontainers.image.source="https://github.com/XGC-Team/xgc2-app-store"
LABEL org.opencontainers.image.version="1.2.3"

ARG XGC2_APT_BASE_URL=https://xgc2.apt.xiaokang.ink
ARG QGC_APPIMAGE_URL=https://github.com/mavlink/qgroundcontrol/releases/download/v4.4.4/QGroundControl.AppImage
ARG QGC_APPIMAGE_SHA256=c0356bfed3ca1c02fafd36d3168cd532590a894c787d612aa237a0cfc0b48580

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=noetic
ENV DISABLE_ROS1_EOL_WARNINGS=1
ENV XGC2_SIM_LOG_DIR=/var/log/xgc2-sim
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY packages.lock /tmp/xgc2-central-sim-packages.lock
COPY scripts/install-products.sh /tmp/install-products.sh

RUN chmod +x /tmp/install-products.sh \
    && XGC2_APT_BASE_URL="${XGC2_APT_BASE_URL}" \
      /tmp/install-products.sh /tmp/xgc2-central-sim-packages.lock \
    && install -D -m 0644 \
      /tmp/xgc2-central-sim-packages.lock \
      /usr/share/xgc2-central-sim/packages.lock \
    && rm -f /tmp/install-products.sh /tmp/xgc2-central-sim-packages.lock \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/install-qgroundcontrol.sh /tmp/install-qgroundcontrol.sh

RUN chmod +x /tmp/install-qgroundcontrol.sh \
    && QGC_APPIMAGE_URL="${QGC_APPIMAGE_URL}" \
      QGC_APPIMAGE_SHA256="${QGC_APPIMAGE_SHA256}" \
      /tmp/install-qgroundcontrol.sh \
    && rm -f /tmp/install-qgroundcontrol.sh

RUN apt-get update \
    && apt-get install -y --no-install-recommends libpulse-mainloop-glib0 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/entrypoint.sh /usr/local/bin/xgc2-central-sim-entrypoint
COPY scripts/healthcheck.sh /usr/local/bin/xgc2-central-sim-healthcheck
COPY scripts/smoke-simulation.sh /usr/local/bin/xgc2-central-sim-smoke
COPY scripts/qgroundcontrol.sh /usr/local/bin/qgroundcontrol
COPY scripts/xgc-process-launcher /usr/local/bin/xgc-process-launcher
COPY --from=execution-runner-build /out/xgc-process-runner /usr/local/bin/xgc-process-runner

RUN chmod +x \
      /usr/local/bin/xgc2-central-sim-entrypoint \
      /usr/local/bin/xgc2-central-sim-healthcheck \
      /usr/local/bin/xgc2-central-sim-smoke \
      /usr/local/bin/xgc-process-launcher \
      /usr/local/bin/xgc-process-runner \
      /usr/local/bin/qgroundcontrol \
    && /usr/local/bin/xgc2-central-sim-healthcheck

RUN mkdir -p \
      "${XGC2_SIM_LOG_DIR}" \
      /run/xgc/processes \
      /var/log/xgc/processes \
      /home/xgc_ws \
      /var/lib/xgc2/qgroundcontrol/config \
      /var/lib/xgc2/qgroundcontrol/cache

WORKDIR /home/xgc_ws

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/xgc2-central-sim-entrypoint"]
CMD ["bash"]
