# syntax=docker/dockerfile:1.7
ARG PARENT_IMAGE=ghcr.io/xgc-team/xgc2-images/xgc2-build-focal-dev:1.0.0
FROM ${PARENT_IMAGE}

LABEL org.opencontainers.image.title="XGC2 focal noetic CI ros"
LABEL org.opencontainers.image.description="Ubuntu focal + official ROS noetic CI image for compiling product sources. No XGC2 APT packages."
LABEL org.opencontainers.image.source="https://github.com/XGC-Team/xgc2-images"

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV ROS_DISTRO=noetic
ENV DISABLE_ROS1_EOL_WARNINGS=1
ENV PATH="/usr/local/go/bin:/usr/local/cargo/bin:/usr/local/bin:${PATH}"
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV UV_PYTHON_INSTALL_DIR=/usr/local/share/uv/python
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY scripts/build/ /tmp/xgc2-build/
COPY apps/xgc2-build-focal-ros-noetic/scripts/healthcheck.sh /usr/local/bin/xgc2-build-healthcheck

RUN chmod +x /tmp/xgc2-build/*.sh /usr/local/bin/xgc2-build-healthcheck \
 && cp /tmp/xgc2-build/assert-no-xgc2-apt.sh /usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh \
 && chmod +x /usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh \
 && printf 'Acquire::Retries "5";\n' >/etc/apt/apt.conf.d/99-xgc2-retries \
 && /tmp/xgc2-build/install-ros-apt-source.sh noetic focal \
 && /tmp/xgc2-build/install-packages.sh /tmp/xgc2-build/packages/ros-tools-noetic.txt \
 && /tmp/xgc2-build/install-ros-packages.sh noetic /tmp/xgc2-build/packages/ros-noetic.txt \
 && /tmp/xgc2-build/assert-no-xgc2-apt.sh \
 && rm -rf /tmp/xgc2-build /var/lib/apt/lists/*

WORKDIR /work
CMD ["bash"]
