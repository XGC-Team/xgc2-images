# syntax=docker/dockerfile:1.7
ARG PARENT_IMAGE=ghcr.io/xgc-team/xgc2-images/xgc2-build-bionic-dev:1.0.0
FROM ${PARENT_IMAGE}

LABEL org.opencontainers.image.title="XGC2 bionic melodic CI ros"
LABEL org.opencontainers.image.description="Ubuntu bionic + official ROS melodic CI image for compiling product sources. No XGC2 APT packages."
LABEL org.opencontainers.image.source="https://github.com/XGC-Team/xgc2-images"

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV ROS_DISTRO=melodic
ENV DISABLE_ROS1_EOL_WARNINGS=1
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY scripts/build/ /tmp/xgc2-build/
COPY apps/xgc2-build-bionic-ros-melodic/scripts/healthcheck.sh /usr/local/bin/xgc2-build-healthcheck

RUN chmod +x /tmp/xgc2-build/*.sh /usr/local/bin/xgc2-build-healthcheck \
 && cp /tmp/xgc2-build/assert-no-xgc2-apt.sh /usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh \
 && chmod +x /usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh \
 && printf 'Acquire::Retries "5";\n' >/etc/apt/apt.conf.d/99-xgc2-retries \
 && /tmp/xgc2-build/install-ros-apt-source.sh melodic bionic \
 && /tmp/xgc2-build/install-packages.sh /tmp/xgc2-build/packages/ros-tools-melodic.txt \
 && /tmp/xgc2-build/install-ros-packages.sh melodic /tmp/xgc2-build/packages/ros-melodic.txt \
 && /tmp/xgc2-build/assert-no-xgc2-apt.sh \
 && rm -rf /tmp/xgc2-build /var/lib/apt/lists/*

WORKDIR /work
CMD ["bash"]
