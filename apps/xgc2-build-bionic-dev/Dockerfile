# syntax=docker/dockerfile:1.7
ARG PARENT_IMAGE=ghcr.io/xgc-team/xgc2-images/xgc2-build-bionic-base:1.0.1
FROM ${PARENT_IMAGE}

LABEL org.opencontainers.image.title="XGC2 bionic CI dev"
LABEL org.opencontainers.image.description="Ubuntu bionic CI compile and Debian packaging image with compilers, Node, pnpm, uv, Go, Rust, and packaging tools. No ROS and no XGC2 APT packages."
LABEL org.opencontainers.image.source="https://github.com/XGC-Team/xgc2-images"

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV PATH="/usr/local/go/bin:/usr/local/cargo/bin:/usr/local/bin:${PATH}"
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV UV_PYTHON_INSTALL_DIR=/usr/local/share/uv/python
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY scripts/build/ /tmp/xgc2-build/
COPY --from=tool-scripts onboard-baseline/configure-ubuntu-mirror.sh /tmp/xgc2-build/
COPY --from=tool-scripts onboard-baseline/prepare-apt.sh /tmp/xgc2-build/
COPY --from=tool-scripts scripts/build/install-toolchains.sh /tmp/xgc2-build/
COPY apps/xgc2-build-bionic-dev/scripts/healthcheck.sh /usr/local/bin/xgc2-build-healthcheck

RUN chmod +x /tmp/xgc2-build/*.sh /usr/local/bin/xgc2-build-healthcheck \
 && cp /tmp/xgc2-build/assert-no-xgc2-apt.sh /usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh \
 && chmod +x /usr/local/bin/xgc2-build-assert-no-xgc2-apt.sh \
 && printf 'Acquire::Retries "5";\n' >/etc/apt/apt.conf.d/99-xgc2-retries \
 && /tmp/xgc2-build/install-packages.sh /tmp/xgc2-build/packages/dev.txt /tmp/xgc2-build/packages/dev-bionic.txt \
 && /tmp/xgc2-build/install-toolchains.sh \
 && /tmp/xgc2-build/assert-no-xgc2-apt.sh \
 && rm -rf /tmp/xgc2-build /var/lib/apt/lists/*

# Keep the existing compiler/toolchain layer reusable; only the pinned CMake
# supply changes for this image revision.
COPY apps/xgc2-build-bionic-dev/scripts/install-pinned-cmake.sh /tmp/install-pinned-cmake.sh
RUN bash /tmp/install-pinned-cmake.sh && rm -f /tmp/install-pinned-cmake.sh

# .conda archives are zstd-compressed tar payloads. Keep the extractor
# app-scoped; no shared toolchain or host change.
RUN apt-get update \
 && apt-get install -y --no-install-recommends zstd \
 && rm -rf /var/lib/apt/lists/*

# Private acados code-generation interpreter for Ubuntu 18.04. The system
# Python/ROS Python 3.6 stays untouched; the pinned wheels are installed only
# into this copied private prefix during the image build.
COPY apps/xgc2-build-bionic-dev/lock/acados-codegen-wheels.lock \
     apps/xgc2-build-bionic-dev/lock/acados-codegen-runtime.lock \
     apps/xgc2-build-bionic-dev/scripts/install-acados-codegen-python.sh \
     /tmp/acados-codegen/
RUN bash /tmp/acados-codegen/install-acados-codegen-python.sh \
 && rm -rf /tmp/acados-codegen

WORKDIR /work
CMD ["bash"]
