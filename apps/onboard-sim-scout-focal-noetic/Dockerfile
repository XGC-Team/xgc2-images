# syntax=docker/dockerfile:1.7
ARG PARENT_IMAGE=ros:noetic-ros-core-focal
FROM scratch AS runtime-sources
COPY onboard-baseline/baselines.json /onboard-baseline/baselines.json
COPY onboard-baseline/onboard-baseline.sh /onboard-baseline/onboard-baseline.sh
COPY onboard-baseline/configure-ubuntu-mirror.sh /onboard-baseline/configure-ubuntu-mirror.sh
COPY onboard-baseline/install-source-deps.sh /onboard-baseline/install-source-deps.sh
COPY scripts/build/install-toolchains.sh /onboard-baseline/install-toolchains.sh
COPY onboard-baseline/image-entrypoint.sh /onboard-baseline/image-entrypoint.sh
COPY onboard-baseline/image-healthcheck.sh /onboard-baseline/image-healthcheck.sh
COPY onboard-baseline/assert-base-only.sh /onboard-baseline/assert-base-only.sh
COPY scripts/build/install-ros-apt-source.sh /onboard-baseline/install-ros-apt-source.sh

FROM ${PARENT_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
ENV ONBOARD_BASELINE_PROFILE=scout-focal-noetic
ENV ONBOARD_BASELINE_USER=nvidia
ENV ROS_DISTRO=noetic
ENV DISABLE_ROS1_EOL_WARNINGS=1
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
ENV PATH="/usr/local/go/bin:/usr/local/cargo/bin:${PATH}"

COPY --from=runtime-sources /onboard-baseline/ /opt/xgc2/onboard-baseline/

ARG ONBOARD_APT_MIRROR
RUN bash <<'EOF'
set -euo pipefail
useradd --uid 1000 --create-home --shell /bin/bash --user-group "$ONBOARD_BASELINE_USER"
chmod 0755 /opt/xgc2/onboard-baseline/*.sh
/opt/xgc2/onboard-baseline/onboard-baseline.sh apply --profile scout-focal-noetic
# Validate as the existing robot operator, not the privileged installer.
runuser -u "$ONBOARD_BASELINE_USER" -- /opt/xgc2/onboard-baseline/onboard-baseline.sh check --profile "$ONBOARD_BASELINE_PROFILE"
rm -rf /var/cache/xgc2-onboard /var/lib/apt/lists/*
EOF


RUN /opt/xgc2/onboard-baseline/assert-base-only.sh

ENTRYPOINT ["/ros_entrypoint.sh"]
CMD ["bash"]
