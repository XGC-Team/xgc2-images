# syntax=docker/dockerfile:1.7
ARG PARENT_IMAGE=ghcr.io/xgc-team/xgc2-images/xgc2-build-noble-ros-jazzy:1.0.2
FROM ${PARENT_IMAGE}

LABEL org.opencontainers.image.title="XGC2 noble jazzy CI full"
LABEL org.opencontainers.image.description="Ubuntu noble + official ROS jazzy full CI image including simulation and vision stacks. No XGC2 APT packages."
LABEL org.opencontainers.image.source="https://github.com/XGC-Team/xgc2-images"

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV ROS_DISTRO=jazzy
ENV PATH="/usr/local/go/bin:/usr/local/cargo/bin:/usr/local/bin:${PATH}"
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV UV_PYTHON_INSTALL_DIR=/usr/local/share/uv/python
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY scripts/build/ /tmp/xgc2-build/
COPY apps/xgc2-build-noble-full-jazzy/scripts/healthcheck.sh /usr/local/bin/xgc2-build-healthcheck
COPY apps/xgc2-build-focal-full-noetic/native-vrpn/ /usr/local/share/xgc2/vrpn-native/

RUN chmod +x /tmp/xgc2-build/*.sh /usr/local/bin/xgc2-build-healthcheck \
 && cp /tmp/xgc2-build/assert-no-xgc2-apt.sh /usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh \
 && chmod +x /usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh \
 && printf 'Acquire::Retries "5";\n' >/etc/apt/apt.conf.d/99-xgc2-retries \
 && /tmp/xgc2-build/install-packages.sh /tmp/xgc2-build/packages/full-sys-noble.txt \
 && /tmp/xgc2-build/install-ros-packages.sh jazzy /tmp/xgc2-build/packages/full-jazzy.txt \
 && CC=cc CXX=c++ python3 /usr/local/share/xgc2/vrpn-native/build.py \
      --work-dir /tmp/xgc2-vrpn-native-build --prefix /tmp/xgc2-vrpn-native-prefix \
 && install -d /opt/xgc2 \
 && cp -a /tmp/xgc2-vrpn-native-prefix /opt/xgc2/vrpn-native \
 && rm -rf /tmp/xgc2-vrpn-native-build /tmp/xgc2-vrpn-native-prefix \
 && /tmp/xgc2-build/assert-no-xgc2-apt.sh \
 && rm -rf /tmp/xgc2-build /var/lib/apt/lists/*

WORKDIR /work
CMD ["bash"]
