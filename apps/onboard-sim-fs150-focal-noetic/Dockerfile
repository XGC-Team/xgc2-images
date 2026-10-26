# syntax=docker/dockerfile:1.7
ARG PARENT_IMAGE=ros:noetic-ros-core-focal
FROM scratch AS runtime-sources
COPY --from=tool-scripts onboard-baseline/baselines.json /onboard-baseline/baselines.json
COPY --from=tool-scripts onboard-baseline/onboard-baseline.sh /onboard-baseline/onboard-baseline.sh
COPY --from=tool-scripts onboard-baseline/configure-ubuntu-mirror.sh /onboard-baseline/configure-ubuntu-mirror.sh
COPY --from=tool-scripts onboard-baseline/prepare-apt.sh /onboard-baseline/prepare-apt.sh
COPY --from=tool-scripts onboard-baseline/configure-product-apt.sh /onboard-baseline/configure-product-apt.sh
COPY --from=tool-scripts onboard-baseline/install-source-deps.sh /onboard-baseline/install-source-deps.sh
COPY apps/onboard-sim-fs150-focal-noetic/install-zenoh.sh /onboard-baseline/install-zenoh.sh
COPY --from=tool-scripts scripts/build/install-toolchains.sh /onboard-baseline/install-toolchains.sh
COPY onboard-baseline/image-healthcheck.sh /onboard-baseline/image-healthcheck.sh
COPY onboard-baseline/assert-base-only.sh /onboard-baseline/assert-base-only.sh
COPY --from=tool-scripts scripts/build/install-ros-apt-source.sh /onboard-baseline/install-ros-apt-source.sh

FROM ${PARENT_IMAGE} AS runtime
ENV DEBIAN_FRONTEND=noninteractive
ENV ONBOARD_BASELINE_PROFILE=fs150-focal-noetic
ENV ONBOARD_BASELINE_USER=marvsmart
ENV ONBOARD_IMAGE_ROLE=runtime
ENV ROS_DISTRO=noetic
ENV DISABLE_ROS1_EOL_WARNINGS=1
COPY --from=runtime-sources /onboard-baseline/ /opt/xgc2/onboard-baseline/
COPY apps/onboard-sim-fs150-focal-noetic/simulation-packages/ /opt/xgc2/onboard-baseline/simulation-packages/
COPY apps/onboard-sim-fs150-focal-noetic/runtime-packages.txt /opt/xgc2/onboard-baseline/runtime-packages.txt
COPY apps/onboard-sim-fs150-focal-noetic/check-simulation.sh /opt/xgc2/onboard-baseline/check-simulation.sh
COPY apps/onboard-sim-fs150-focal-noetic/check-image.sh /opt/xgc2/onboard-baseline/check-image.sh
ARG ONBOARD_APT_MIRROR
RUN bash <<'EOF'
set -euo pipefail
if [[ -z "${ONBOARD_APT_MIRROR:-}" ]]; then
  case "$(dpkg --print-architecture)" in
    amd64) export ONBOARD_APT_MIRROR=https://archive.ubuntu.com/ubuntu ;;
    arm64) export ONBOARD_APT_MIRROR=https://ports.ubuntu.com/ubuntu-ports ;;
  esac
fi
useradd --uid 1000 --create-home --shell /bin/bash --user-group "$ONBOARD_BASELINE_USER"
chmod 0755 /opt/xgc2/onboard-baseline/*.sh
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 0755 /usr/sbin/policy-rc.d
/opt/xgc2/onboard-baseline/prepare-apt.sh
/opt/xgc2/onboard-baseline/configure-ubuntu-mirror.sh
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg
/opt/xgc2/onboard-baseline/configure-product-apt.sh https://xgc2.apt.xiaokang.ink focal
apt-get update
packages=/opt/xgc2/onboard-baseline/simulation-packages
cat "$packages/common.txt" "$packages/$(dpkg --print-architecture).txt" > /opt/xgc2/onboard-baseline/simulation-packages.txt
cat /opt/xgc2/onboard-baseline/runtime-packages.txt /opt/xgc2/onboard-baseline/simulation-packages.txt | xargs -r apt-get install -y --no-install-recommends
/opt/xgc2/onboard-baseline/install-zenoh.sh apply
install -D -m 0755 /opt/xgc2/onboard-baseline/install-zenoh.sh /usr/local/lib/xgc2/zenoh-baseline/install-zenoh.sh
geographiclib-get-geoids egm96-5
/opt/xgc2/onboard-baseline/check-image.sh
/opt/xgc2/onboard-baseline/assert-base-only.sh
rm -rf /var/lib/apt/lists/*
EOF
ENTRYPOINT ["/ros_entrypoint.sh"]
CMD ["bash"]

FROM runtime AS builder
COPY apps/onboard-sim-fs150-focal-noetic/builder-packages.txt /opt/xgc2/onboard-baseline/builder-packages.txt
ENV ONBOARD_IMAGE_ROLE=builder
ENV PATH="/usr/local/go/bin:${PATH}"
RUN bash <<'EOF'
set -euo pipefail
if [[ -z "${ONBOARD_APT_MIRROR:-}" ]]; then
  case "$(dpkg --print-architecture)" in
    amd64) export ONBOARD_APT_MIRROR=https://archive.ubuntu.com/ubuntu ;;
    arm64) export ONBOARD_APT_MIRROR=https://ports.ubuntu.com/ubuntu-ports ;;
  esac
fi
/opt/xgc2/onboard-baseline/onboard-baseline.sh apply --profile fs150-focal-noetic --replace-timesyncd
apt-get update
xargs -r apt-get install -y --no-install-recommends < /opt/xgc2/onboard-baseline/builder-packages.txt
runuser -u "$ONBOARD_BASELINE_USER" -- /opt/xgc2/onboard-baseline/onboard-baseline.sh check --profile "$ONBOARD_BASELINE_PROFILE"
/opt/xgc2/onboard-baseline/check-image.sh
/opt/xgc2/onboard-baseline/assert-base-only.sh
rm -rf /var/cache/xgc2-onboard /var/lib/apt/lists/*
EOF
