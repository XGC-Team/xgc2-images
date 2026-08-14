# syntax=docker/dockerfile:1.7
FROM osrf/ros:jazzy-desktop-full

LABEL org.opencontainers.image.title="XGC2 Development Workstation"
LABEL org.opencontainers.image.description="ROS 2 Jazzy development workstation with Qt development packages and Docker CLI."
LABEL org.opencontainers.image.source="https://github.com/XGC-Team/xgc2-images"

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=jazzy
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY scripts/entrypoint.sh /usr/local/bin/xgc-entrypoint
COPY scripts/healthcheck.sh /usr/local/bin/xgc2-dev-healthcheck

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      cmake \
      curl \
      docker.io \
      g++ \
      git \
      gosu \
      iputils-ping \
      libgl1-mesa-dev \
      libxkbcommon-x11-dev \
      ninja-build \
      pkg-config \
      python3-pip \
      qt6-base-dev \
      qt6-declarative-dev \
      qt6-svg-dev \
      qt6-tools-dev \
      qt6-wayland \
      ros-dev-tools \
      sudo \
      vim \
    && chmod +x /usr/local/bin/xgc-entrypoint /usr/local/bin/xgc2-dev-healthcheck \
    && git config --system --add safe.directory '*' \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/xgc-entrypoint"]
CMD ["bash"]
