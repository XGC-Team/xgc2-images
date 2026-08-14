FROM ghcr.io/lxk36/xgc2-app-store/xgc-ros1-runtime:1.2.3

LABEL org.opencontainers.image.title="XGC1 Focal Noetic Qt Builder"
LABEL org.opencontainers.image.description="Multi-architecture ROS Noetic build image with Qt 5.15.2 compiled from source for XGC1 packaging."
LABEL org.opencontainers.image.source="https://github.com/XGC-Team/xgc2-images"

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=noetic
ENV DISABLE_ROS1_EOL_WARNINGS=1
ENV XGC1_QT_PREFIX=/opt/xgc1/toolchains/qt/5.15.2
ENV QT_PATH=/opt/xgc1/toolchains/qt/5.15.2
ENV PATH=/opt/xgc1/toolchains/qt/5.15.2/bin:${PATH}
ENV LD_LIBRARY_PATH=/opt/xgc1/toolchains/qt/5.15.2/lib
ENV QT_PLUGIN_PATH=/opt/xgc1/toolchains/qt/5.15.2/plugins
ENV CMAKE_PREFIX_PATH=/opt/ros/noetic:/opt/xgc1/toolchains/qt/5.15.2
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG QT_SOURCE_URL=https://download.qt.io/archive/qt/5.15/5.15.2/single/qt-everywhere-src-5.15.2.tar.xz
ARG QT_SOURCE_FALLBACK_URL=https://cloud.xiaokang.ink/f/MxUB/qt-everywhere-src-5.15.2.tar.xz

COPY scripts/install-qt-5.15.2.sh /tmp/install-qt-5.15.2.sh
COPY scripts/healthcheck.sh /usr/local/bin/xgc1-qt-builder-healthcheck

RUN chmod +x /tmp/install-qt-5.15.2.sh /usr/local/bin/xgc1-qt-builder-healthcheck \
    && /tmp/install-qt-5.15.2.sh \
    && rm -f /tmp/install-qt-5.15.2.sh \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

CMD ["bash"]
