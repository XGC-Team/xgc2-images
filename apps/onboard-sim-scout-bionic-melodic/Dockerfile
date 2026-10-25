# syntax=docker/dockerfile:1.7
ARG PARENT_IMAGE=ros:melodic-ros-core-bionic
FROM scratch AS runtime-sources
COPY --from=tool-scripts onboard-baseline/baselines.json /onboard-baseline/baselines.json
COPY --from=tool-scripts onboard-baseline/onboard-baseline.sh /onboard-baseline/onboard-baseline.sh
COPY --from=tool-scripts onboard-baseline/configure-ubuntu-mirror.sh /onboard-baseline/configure-ubuntu-mirror.sh
COPY --from=tool-scripts onboard-baseline/install-source-deps.sh /onboard-baseline/install-source-deps.sh
COPY --from=tool-scripts scripts/build/install-toolchains.sh /onboard-baseline/install-toolchains.sh
COPY onboard-baseline/image-entrypoint.sh /onboard-baseline/image-entrypoint.sh
COPY onboard-baseline/image-healthcheck.sh /onboard-baseline/image-healthcheck.sh
COPY onboard-baseline/assert-base-only.sh /onboard-baseline/assert-base-only.sh
COPY --from=tool-scripts scripts/build/install-ros-apt-source.sh /onboard-baseline/install-ros-apt-source.sh

FROM ${PARENT_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
ENV ONBOARD_BASELINE_PROFILE=scout-bionic-melodic
ENV ONBOARD_BASELINE_USER=agilex
ENV ROS_DISTRO=melodic
ENV DISABLE_ROS1_EOL_WARNINGS=1
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
ENV PATH="/usr/local/go/bin:/usr/local/cargo/bin:${PATH}"

COPY --from=runtime-sources /onboard-baseline/ /opt/xgc2/onboard-baseline/

ARG ONBOARD_APT_MIRROR
RUN bash <<'EOF'
set -euo pipefail
useradd --uid 1000 --create-home --shell /bin/bash --user-group "$ONBOARD_BASELINE_USER"
chmod 0755 /opt/xgc2/onboard-baseline/*.sh
# No daemon startup during image preparation.
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 0755 /usr/sbin/policy-rc.d
/opt/xgc2/onboard-baseline/onboard-baseline.sh apply --profile scout-bionic-melodic --replace-timesyncd
# Validate as the existing robot operator, not the privileged installer.
runuser -u "$ONBOARD_BASELINE_USER" -- /opt/xgc2/onboard-baseline/onboard-baseline.sh check --profile "$ONBOARD_BASELINE_PROFILE"
rm -rf /var/cache/xgc2-onboard /var/lib/apt/lists/*
EOF


RUN /opt/xgc2/onboard-baseline/assert-base-only.sh

ENTRYPOINT ["/ros_entrypoint.sh"]
CMD ["bash"]
