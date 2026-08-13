FROM ros:noetic-ros-base-focal

LABEL org.opencontainers.image.title="ROS1 Simulation Kit"
LABEL org.opencontainers.image.description="Curated ROS Noetic simulation toolkit with MAVROS, VRPN, Gazebo Classic and core robot visualization dependencies."
LABEL org.opencontainers.image.source="https://github.com/XGC-Team/xgc2-app-store"

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=noetic
ENV DISABLE_ROS1_EOL_WARNINGS=1
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY scripts/install-runtime-deps.sh /tmp/install-runtime-deps.sh
COPY scripts/entrypoint.sh /usr/local/bin/xgc-ros1-entrypoint
COPY scripts/healthcheck.sh /usr/local/bin/xgc-ros1-healthcheck

RUN chmod +x /tmp/install-runtime-deps.sh /usr/local/bin/xgc-ros1-entrypoint /usr/local/bin/xgc-ros1-healthcheck \
    && /tmp/install-runtime-deps.sh \
    && rm -f /tmp/install-runtime-deps.sh \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /home

ENTRYPOINT ["/usr/local/bin/xgc-ros1-entrypoint"]
CMD ["bash"]
