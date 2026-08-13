# syntax=docker/dockerfile:1.7
ARG PARENT_IMAGE=ubuntu:20.04
FROM ${PARENT_IMAGE}

LABEL org.opencontainers.image.title="XGC2 focal CI base"
LABEL org.opencontainers.image.description="Ubuntu focal CI base with apt hygiene only. No compilers, ROS, or XGC2 APT packages."
LABEL org.opencontainers.image.source="https://github.com/lxk36/xgc2-app-store"

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY scripts/build/ /tmp/xgc2-build/
COPY apps/xgc2-build-focal-base/scripts/healthcheck.sh /usr/local/bin/xgc2-build-healthcheck

RUN chmod +x /tmp/xgc2-build/*.sh /usr/local/bin/xgc2-build-healthcheck \
 && cp /tmp/xgc2-build/assert-no-xgc2-apt.sh /usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh \
 && chmod +x /usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh \
 && printf 'Acquire::Retries "5";\n' >/etc/apt/apt.conf.d/99-xgc2-retries \
 && /tmp/xgc2-build/install-packages.sh /tmp/xgc2-build/packages/base.txt \
 && locale-gen en_US.UTF-8 \
 && /tmp/xgc2-build/assert-no-xgc2-apt.sh \
 && rm -rf /tmp/xgc2-build /var/lib/apt/lists/*

WORKDIR /work
CMD ["bash"]
