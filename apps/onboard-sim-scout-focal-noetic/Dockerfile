# syntax=docker/dockerfile:1.7
ARG PARENT_IMAGE=ros:noetic-ros-core-focal
FROM scratch AS runtime-sources
COPY onboard-baseline/baselines.json /onboard-baseline/baselines.json
COPY onboard-baseline/onboard-baseline.sh /onboard-baseline/onboard-baseline.sh
COPY onboard-baseline/image-entrypoint.sh /onboard-baseline/image-entrypoint.sh
COPY onboard-baseline/image-healthcheck.sh /onboard-baseline/image-healthcheck.sh
COPY scripts/build/install-ros-apt-source.sh /onboard-baseline/install-ros-apt-source.sh

FROM ${PARENT_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
ENV ONBOARD_BASELINE_PROFILE=scout-focal-noetic
ENV ONBOARD_BASELINE_USER=nvidia
ENV ROS_DISTRO=noetic
ENV DISABLE_ROS1_EOL_WARNINGS=1

COPY --from=runtime-sources /onboard-baseline/ /opt/xgc2/onboard-baseline/

ARG ONBOARD_APT_MIRROR
RUN bash <<'EOF'
set -euo pipefail
useradd --uid 1000 --create-home --shell /bin/bash --user-group "$ONBOARD_BASELINE_USER"
chmod 0755 /opt/xgc2/onboard-baseline/*.sh
if [ -n "${ONBOARD_APT_MIRROR:-}" ]; then
  unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy || true
  for sources in /etc/apt/sources.list /etc/apt/sources.list.d/*; do
    if [ -f "$sources" ] && [ ! -L "$sources" ]; then
      sed -i \
        -e "s|http://archive.ubuntu.com/ubuntu|${ONBOARD_APT_MIRROR}|g" \
        -e "s|http://security.ubuntu.com/ubuntu|${ONBOARD_APT_MIRROR}|g" \
        -e "s|https://archive.ubuntu.com/ubuntu|${ONBOARD_APT_MIRROR}|g" \
        -e "s|https://security.ubuntu.com/ubuntu|${ONBOARD_APT_MIRROR}|g" \
        "$sources"
    fi
  done
fi
/opt/xgc2/onboard-baseline/onboard-baseline.sh apply --profile scout-focal-noetic
# Validate as the existing robot operator, not the privileged installer.
runuser -u "$ONBOARD_BASELINE_USER" -- /opt/xgc2/onboard-baseline/onboard-baseline.sh check --profile "$ONBOARD_BASELINE_PROFILE"
EOF

ENTRYPOINT ["/opt/xgc2/onboard-baseline/image-entrypoint.sh"]
