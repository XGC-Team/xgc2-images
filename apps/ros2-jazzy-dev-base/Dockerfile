# syntax=docker/dockerfile:1.7
FROM osrf/ros:jazzy-desktop-full

LABEL org.opencontainers.image.title="ROS2 Jazzy Development Base"
LABEL org.opencontainers.image.description="ROS 2 Jazzy desktop base with MAVROS, PlotJuggler, VRPN client and common ground-station development tools."
LABEL org.opencontainers.image.source="https://github.com/XGC-Team/xgc2-images"

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=jazzy
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY scripts/entrypoint.sh /usr/local/bin/xgc-entrypoint
COPY scripts/healthcheck.sh /usr/local/bin/xgc-ros2-healthcheck

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      geographiclib-tools \
      git \
      gosu \
      iputils-ping \
      locales \
      mesa-utils \
      python3-pip \
      ros-dev-tools \
      ros-jazzy-mavros \
      ros-jazzy-mavros-extras \
      ros-jazzy-plotjuggler-ros \
      sudo \
      vim \
    && (apt-get install -y --no-install-recommends libvrpn-dev ros-jazzy-vrpn-client-ros || true) \
    && locale-gen en_US en_US.UTF-8 \
    && chmod +x /usr/local/bin/xgc-entrypoint /usr/local/bin/xgc-ros2-healthcheck \
    && rosdep init || true \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/xgc-entrypoint"]
CMD ["bash"]
