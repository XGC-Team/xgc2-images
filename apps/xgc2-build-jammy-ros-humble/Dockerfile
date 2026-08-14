# syntax=docker/dockerfile:1.7
ARG PARENT_IMAGE=ghcr.io/xgc-team/xgc2-images/xgc2-build-jammy-dev:1.0.0
FROM ${PARENT_IMAGE}

LABEL org.opencontainers.image.title="XGC2 jammy humble CI ros"
LABEL org.opencontainers.image.description="Ubuntu jammy + official ROS humble CI image for compiling product sources. No XGC2 APT packages."
LABEL org.opencontainers.image.source="https://github.com/XGC-Team/xgc2-images"

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV ROS_DISTRO=humble
ENV PATH="/usr/local/go/bin:/usr/local/cargo/bin:/usr/local/bin:${PATH}"
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV UV_PYTHON_INSTALL_DIR=/usr/local/share/uv/python
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY scripts/build/ /tmp/xgc2-build/
COPY apps/xgc2-build-jammy-ros-humble/scripts/healthcheck.sh /usr/local/bin/xgc2-build-healthcheck

RUN chmod +x /tmp/xgc2-build/*.sh /usr/local/bin/xgc2-build-healthcheck \
 && cp /tmp/xgc2-build/assert-no-xgc2-apt.sh /usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh \
 && chmod +x /usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh \
 && printf 'Acquire::Retries "5";\n' >/etc/apt/apt.conf.d/99-xgc2-retries \
 && /tmp/xgc2-build/install-ros-apt-source.sh humble jammy \
 && /tmp/xgc2-build/install-packages.sh /tmp/xgc2-build/packages/ros-tools-humble.txt \
 && /tmp/xgc2-build/install-ros-packages.sh humble /tmp/xgc2-build/packages/ros-humble.txt \
 && /tmp/xgc2-build/assert-no-xgc2-apt.sh \
 && rm -rf /tmp/xgc2-build /var/lib/apt/lists/*

WORKDIR /work
CMD ["bash"]
