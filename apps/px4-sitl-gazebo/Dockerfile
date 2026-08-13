FROM osrf/ros:noetic-desktop-full

LABEL org.opencontainers.image.title="PX4 SITL Gazebo"
LABEL org.opencontainers.image.description="PX4 software-in-the-loop simulation toolkit for Gazebo Classic and ROS Noetic."
LABEL org.opencontainers.image.source="https://github.com/XGC-Team/xgc2-app-store"

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=noetic
ENV DISABLE_ROS1_EOL_WARNINGS=1
ENV PX4_AUTOPILOT_HOME=/root/PX4-Autopilot
ENV PX4_SITL_HOME=/root/PX4-Autopilot
ENV PATH=/root/.local/bin:${PATH}
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG PX4_AUTOPILOT_REPO=https://github.com/PX4/PX4-Autopilot.git
ARG PX4_AUTOPILOT_REF=v1.14.4

COPY scripts/install-px4-sitl-deps.sh /tmp/install-px4-sitl-deps.sh
COPY scripts/entrypoint.sh /usr/local/bin/px4-sitl-entrypoint
COPY scripts/healthcheck.sh /usr/local/bin/px4-sitl-healthcheck

RUN chmod +x /tmp/install-px4-sitl-deps.sh /usr/local/bin/px4-sitl-entrypoint /usr/local/bin/px4-sitl-healthcheck \
    && /tmp/install-px4-sitl-deps.sh \
    && git clone --depth 1 --branch "${PX4_AUTOPILOT_REF}" --recursive "${PX4_AUTOPILOT_REPO}" "${PX4_AUTOPILOT_HOME}" \
    && git -C "${PX4_AUTOPILOT_HOME}" submodule update --init --recursive --depth 1 \
    && cd "${PX4_AUTOPILOT_HOME}" \
    && bash ./Tools/setup/ubuntu.sh \
    && DONT_RUN=1 make px4_sitl gazebo-classic \
    && rm -f /tmp/install-px4-sitl-deps.sh \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /root/PX4-Autopilot

ENTRYPOINT ["/usr/local/bin/px4-sitl-entrypoint"]
CMD ["bash", "-lc", "make px4_sitl ${PX4_GAZEBO_TARGET:-gazebo-classic}"]
