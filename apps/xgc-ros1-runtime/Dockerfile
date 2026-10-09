FROM ghcr.io/xgc-team/xgc2-images/xgc2-build-focal-full-noetic:1.0.0 AS gazebo-rendering-build
COPY apps/xgc-ros1-runtime/scripts/gazebo/ /tmp/gazebo-build/
RUN bash /tmp/gazebo-build/build-rendering.sh /out /tmp/gazebo-source

FROM ros:noetic-ros-base-focal

LABEL org.opencontainers.image.title="ROS1 Simulation Kit"
LABEL org.opencontainers.image.description="Curated ROS Noetic simulation toolkit with MAVROS, VRPN, Gazebo Classic and core robot visualization dependencies."
LABEL org.opencontainers.image.source="https://github.com/XGC-Team/xgc2-images"

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=noetic
ENV DISABLE_ROS1_EOL_WARNINGS=1
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY apps/xgc-ros1-runtime/scripts/install-runtime-deps.sh /tmp/install-runtime-deps.sh
COPY apps/xgc-ros1-runtime/scripts/entrypoint.sh /usr/local/bin/xgc-ros1-entrypoint
COPY apps/xgc-ros1-runtime/scripts/healthcheck.sh /usr/local/bin/xgc-ros1-healthcheck
COPY apps/xgc2-build-focal-dev/xrpc/ /tmp/xgc2-xrpc-deps/

RUN chmod +x /tmp/install-runtime-deps.sh /usr/local/bin/xgc-ros1-entrypoint /usr/local/bin/xgc-ros1-healthcheck \
    && /tmp/install-runtime-deps.sh \
    && bash /tmp/xgc2-xrpc-deps/install.sh runtime \
    && rm -rf /tmp/xgc2-xrpc-deps \
    && rm -f /tmp/install-runtime-deps.sh \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY --from=gazebo-rendering-build /out/libgazebo_rendering.so.11.15.1 /tmp/libgazebo_rendering.so.11.15.1
COPY --from=gazebo-rendering-build /out/COPYING.gazebo /usr/local/share/doc/gazebo-rendering/COPYING
COPY apps/xgc-ros1-runtime/scripts/gazebo/gpu-laser-material.patch /usr/local/share/doc/gazebo-rendering/
# NVIDIA's container hook rebuilds the loader cache with distribution paths
# first. Replace the package's actual library, rather than keeping two SONAMEs.
RUN library="$(dpkg-query -L libgazebo11 | sed -n '/\/libgazebo_rendering.so.11.15.1$/p')" \
    && mkdir -p /usr/local/share/gazebo-rendering/original \
    && dpkg-divert --local --rename \
      --divert /usr/local/share/gazebo-rendering/original/libgazebo_rendering.so.11.15.1 \
      --add "${library}" \
    && install -m 0644 /tmp/libgazebo_rendering.so.11.15.1 "${library}" \
    && rm /tmp/libgazebo_rendering.so.11.15.1 \
    && ldconfig

WORKDIR /home

ENTRYPOINT ["/usr/local/bin/xgc-ros1-entrypoint"]
CMD ["bash"]
