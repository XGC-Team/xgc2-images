FROM ghcr.io/xgc-team/xgc2-images/xgc2-build-focal-full-noetic:1.0.0 AS gazebo-rendering-build
COPY scripts/gazebo/ /tmp/gazebo-build/
RUN bash /tmp/gazebo-build/build-rendering.sh /out /tmp/gazebo-source

FROM ghcr.io/xgc-team/xgc2-images/xgc2-build-focal-full-noetic:1.0.0 AS rosbag-record-build
COPY scripts/rosbag/ /tmp/rosbag-build/
RUN apt-get update \
    && apt-get install -y --no-install-recommends libgpgme-dev libssl-dev libbz2-dev \
      ros-noetic-rosbag ros-noetic-rosbag-storage \
    && bash /tmp/rosbag-build/build-record.sh /out /tmp/rosbag-source

FROM ros:noetic-ros-base-focal

LABEL org.opencontainers.image.title="ROS1 Simulation Kit"
LABEL org.opencontainers.image.description="Curated ROS Noetic simulation toolkit with MAVROS, VRPN, Gazebo Classic and core robot visualization dependencies."
LABEL org.opencontainers.image.source="https://github.com/XGC-Team/xgc2-images"
LABEL org.opencontainers.image.version="1.2.5"

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

COPY --from=gazebo-rendering-build /out/libgazebo_rendering.so.11.15.1 /tmp/libgazebo_rendering.so.11.15.1
COPY --from=gazebo-rendering-build /out/COPYING.gazebo /usr/local/share/doc/gazebo-rendering/COPYING
COPY scripts/gazebo/gpu-laser-material.patch /usr/local/share/doc/gazebo-rendering/
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

# Install the matching recorder/template-consumer and storage/encryptor closure
# at the normal owning ROS package paths, with no runtime overlay or wrapper.
COPY --from=rosbag-record-build /out/ /tmp/rosbag-record/
COPY scripts/rosbag/pure-write-mirror.patch /usr/local/share/doc/rosbag-record/
RUN apt-get update \
    && apt-get install -y --no-install-recommends ros-noetic-rosbag ros-noetic-rosbag-storage \
    && mkdir -p /usr/local/share/rosbag-record/original /usr/local/share/doc/rosbag-record \
    && for path in lib/rosbag/record lib/librosbag.so lib/librosbag_storage.so \
      lib/librosbag_default_encryption_plugins.so include/rosbag/bag.h; do \
      mkdir -p "/usr/local/share/rosbag-record/original/$(dirname "${path}")"; \
      dpkg-divert --local --rename \
        --divert "/usr/local/share/rosbag-record/original/${path}" \
        --add "/opt/ros/noetic/${path}"; \
      if [[ "${path}" == lib/rosbag/record ]]; then mode=0755; else mode=0644; fi; \
      install -m "${mode}" "/tmp/rosbag-record/${path}" "/opt/ros/noetic/${path}"; \
    done \
    && install -m 0644 /tmp/rosbag-record/COPYING.rosbag /tmp/rosbag-record/SOURCE.rosbag \
      /usr/local/share/doc/rosbag-record/ \
    && rm -rf /tmp/rosbag-record \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && ldconfig

WORKDIR /home

ENTRYPOINT ["/usr/local/bin/xgc-ros1-entrypoint"]
CMD ["bash"]
