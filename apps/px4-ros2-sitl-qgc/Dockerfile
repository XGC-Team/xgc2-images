# syntax=docker/dockerfile:1.7
FROM osrf/ros:jazzy-desktop-full

LABEL org.opencontainers.image.title="PX4 ROS2 SITL with QGC"
LABEL org.opencontainers.image.description="PX4 ROS 2 SITL development image with Micro XRCE-DDS Agent and QGroundControl AppImage included."
LABEL org.opencontainers.image.source="https://github.com/XGC-Team/xgc2-app-store"

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=jazzy
ENV PX4_AUTOPILOT_HOME=/opt/PX4-Autopilot
ENV MICRO_XRCE_DDS_AGENT_HOME=/opt/Micro-XRCE-DDS-Agent
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG PX4_AUTOPILOT_REPO=https://github.com/PX4/PX4-Autopilot.git
ARG PX4_AUTOPILOT_REF=v1.16.0
ARG MICRO_XRCE_DDS_AGENT_REPO=https://github.com/eProsima/Micro-XRCE-DDS-Agent.git
ARG MICRO_XRCE_DDS_AGENT_REF=v2.4.3
ARG QGC_APPIMAGE_URL=https://github.com/mavlink/qgroundcontrol/releases/download/v4.4.4/QGroundControl.AppImage
ARG QGC_APPIMAGE_SHA256=

COPY scripts/entrypoint.sh /usr/local/bin/xgc-entrypoint
COPY scripts/healthcheck.sh /usr/local/bin/px4-ros2-sitl-healthcheck
COPY scripts/qgroundcontrol.sh /usr/local/bin/qgroundcontrol

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends \
      bash-completion \
      build-essential \
      ca-certificates \
      cmake \
      curl \
      fuse3 \
      g++ \
      git \
      gosu \
      gstreamer1.0-gl \
      gstreamer1.0-libav \
      gstreamer1.0-plugins-bad \
      gstreamer1.0-plugins-base \
      gstreamer1.0-plugins-good \
      gstreamer1.0-plugins-ugly \
      iputils-ping \
      libfuse2t64 \
      libxcb-cursor0 \
      libxcb-xinerama0 \
      libxkbcommon-x11-0 \
      make \
      ninja-build \
      python3-pip \
      sudo \
      wget \
    && python3 -m pip install --break-system-packages --no-cache-dir \
      empy \
      jinja2 \
      jsonschema \
      kconfiglib \
      numpy \
      packaging \
      pyros-genmsg \
      pyyaml \
      toml \
    && git clone --depth 1 --branch "${PX4_AUTOPILOT_REF}" --recursive "${PX4_AUTOPILOT_REPO}" "${PX4_AUTOPILOT_HOME}" \
    && git -C "${PX4_AUTOPILOT_HOME}" submodule update --init --recursive --depth 1 \
    && bash "${PX4_AUTOPILOT_HOME}/Tools/setup/ubuntu.sh" --no-nuttx --no-sim-tools \
    && git clone --depth 1 --branch "${MICRO_XRCE_DDS_AGENT_REF}" "${MICRO_XRCE_DDS_AGENT_REPO}" "${MICRO_XRCE_DDS_AGENT_HOME}" \
    && cmake -S "${MICRO_XRCE_DDS_AGENT_HOME}" -B /tmp/micro-xrce-agent-build -DCMAKE_BUILD_TYPE=Release \
    && cmake --build /tmp/micro-xrce-agent-build --parallel "$(nproc)" \
    && cmake --install /tmp/micro-xrce-agent-build \
    && ldconfig \
    && mkdir -p /opt/qgroundcontrol \
    && curl --fail --location --retry 5 --retry-all-errors --retry-delay 2 "${QGC_APPIMAGE_URL}" -o /opt/qgroundcontrol/QGroundControl.AppImage \
    && if [[ -n "${QGC_APPIMAGE_SHA256}" ]]; then echo "${QGC_APPIMAGE_SHA256}  /opt/qgroundcontrol/QGroundControl.AppImage" | sha256sum -c -; fi \
    && chmod +x /opt/qgroundcontrol/QGroundControl.AppImage /usr/local/bin/xgc-entrypoint /usr/local/bin/px4-ros2-sitl-healthcheck /usr/local/bin/qgroundcontrol \
    && rm -rf /tmp/micro-xrce-agent-build /var/lib/apt/lists/*

WORKDIR /opt/PX4-Autopilot
ENTRYPOINT ["/usr/local/bin/xgc-entrypoint"]
CMD ["bash"]
