# syntax=docker/dockerfile:1.7
ARG PARENT_IMAGE=ghcr.io/lxk36/xgc2-app-store/xgc2-build-focal-base:1.0.0
FROM ${PARENT_IMAGE}

LABEL org.opencontainers.image.title="XGC2 focal CI dev"
LABEL org.opencontainers.image.description="Ubuntu focal CI compile and Debian packaging image. No ROS and no XGC2 APT packages."
LABEL org.opencontainers.image.source="https://github.com/lxk36/xgc2-app-store"

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY scripts/build/ /tmp/xgc2-build/
COPY apps/xgc2-build-focal-dev/scripts/healthcheck.sh /usr/local/bin/xgc2-build-healthcheck

RUN chmod +x /tmp/xgc2-build/*.sh /usr/local/bin/xgc2-build-healthcheck \
 && cp /tmp/xgc2-build/assert-no-xgc2-apt.sh /usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh \
 && chmod +x /usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh \
 && printf 'Acquire::Retries "5";\n' >/etc/apt/apt.conf.d/99-xgc2-retries \
 && /tmp/xgc2-build/install-packages.sh /tmp/xgc2-build/packages/dev.txt /tmp/xgc2-build/packages/dev-focal.txt \
 && /tmp/xgc2-build/assert-no-xgc2-apt.sh \
 && rm -rf /tmp/xgc2-build /var/lib/apt/lists/*

WORKDIR /work
CMD ["bash"]
