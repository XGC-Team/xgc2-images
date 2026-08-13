# syntax=docker/dockerfile:1.7
FROM osrf/ros:jazzy-desktop-full

LABEL org.opencontainers.image.title="Gazebo Harmonic ROS2 Bridge"
LABEL org.opencontainers.image.description="Gazebo Harmonic with ROS 2 Jazzy integration for simulation workloads."
LABEL org.opencontainers.image.source="https://github.com/XGC-Team/xgc2-app-store"

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=jazzy
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY scripts/entrypoint.sh /usr/local/bin/xgc-entrypoint
COPY scripts/healthcheck.sh /usr/local/bin/gazebo-harmonic-healthcheck

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      build-essential \
      cmake \
      curl \
      git \
      gosu \
      iputils-ping \
      libeigen3-dev \
      pkg-config \
      python3-colcon-common-extensions \
      ros-jazzy-fastcdr \
      ros-jazzy-fastrtps \
      ros-jazzy-fastrtps-cmake-module \
      ros-jazzy-rmw-fastrtps-cpp \
      ros-jazzy-rmw-fastrtps-shared-cpp \
      ros-jazzy-rosidl-dynamic-typesupport-fastrtps \
      ros-jazzy-rosidl-typesupport-fastrtps-c \
      ros-jazzy-rosidl-typesupport-fastrtps-cpp \
      ros-jazzy-ros-gz \
      ros-jazzy-rviz2 \
      ros-jazzy-visualization-msgs \
      sudo \
    && chmod +x /usr/local/bin/xgc-entrypoint /usr/local/bin/gazebo-harmonic-healthcheck \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /usr/share/glvnd/egl_vendor.d \
    && printf '%s\n' \
      '{' \
      '    "file_format_version" : "1.0.0",' \
      '    "ICD" : {' \
      '        "library_path" : "libEGL_nvidia.so.0"' \
      '    }' \
      '}' > /usr/share/glvnd/egl_vendor.d/10_nvidia.json

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/xgc-entrypoint"]
CMD ["bash"]
