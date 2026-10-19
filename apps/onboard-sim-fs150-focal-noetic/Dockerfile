# syntax=docker/dockerfile:1.7
ARG PARENT_IMAGE=ros:noetic-ros-core-focal
ARG AGENT_INSTALL=apt
FROM scratch AS runtime-sources
COPY onboard-baseline/baselines.json /onboard-baseline/baselines.json
COPY onboard-baseline/onboard-baseline.sh /onboard-baseline/onboard-baseline.sh
COPY onboard-baseline/image-entrypoint.sh /onboard-baseline/image-entrypoint.sh
COPY onboard-baseline/image-healthcheck.sh /onboard-baseline/image-healthcheck.sh
COPY scripts/build/install-ros-apt-source.sh /onboard-baseline/install-ros-apt-source.sh

FROM ${PARENT_IMAGE} AS baseline

ENV DEBIAN_FRONTEND=noninteractive
ENV ONBOARD_BASELINE_PROFILE=fs150-focal-noetic
ENV ONBOARD_BASELINE_USER=marvsmart
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
/opt/xgc2/onboard-baseline/onboard-baseline.sh apply --profile fs150-focal-noetic
EOF

ENTRYPOINT ["/opt/xgc2/onboard-baseline/image-entrypoint.sh"]

FROM baseline AS apt-agent
ARG ONBOARD_BASELINE_AGENT_VERSION=0.1.0-13
RUN bash <<'EOF'
set -euo pipefail
/opt/xgc2/onboard-baseline/onboard-baseline.sh install-agent --user "$ONBOARD_BASELINE_USER" --profile fs150-focal-noetic
runuser -u "$ONBOARD_BASELINE_USER" -- /opt/xgc2/onboard-baseline/onboard-baseline.sh check --profile "$ONBOARD_BASELINE_PROFILE"
EOF

FROM baseline AS source-agent
RUN --mount=type=bind,from=agentdeb,source=xgc2-agent.deb,target=/tmp/xgc2-agent.deb \
    bash <<'EOF'
set -euo pipefail
apt-get update
apt-get install -y --no-install-recommends /tmp/xgc2-agent.deb
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb
/opt/xgc2/onboard-baseline/onboard-baseline.sh install-agent --user "$ONBOARD_BASELINE_USER" --profile fs150-focal-noetic
runuser -u "$ONBOARD_BASELINE_USER" -- /opt/xgc2/onboard-baseline/onboard-baseline.sh check --profile "$ONBOARD_BASELINE_PROFILE"
EOF

# Optional simulation layer; the shared installer owns both formal runtime packages.
FROM ${AGENT_INSTALL}-agent AS xsim-simulation
ARG ONBOARD_BASELINE_XSIM_VERSION=1.4.0-4
RUN bash <<'EOF'
set -euo pipefail
/opt/xgc2/onboard-baseline/onboard-baseline.sh install-xsim --profile fs150-focal-noetic
set +u
source /opt/ros/noetic/setup.bash
set -u
ldconfig
test -x /opt/xgc2/xsim/bin/xsim
test -r /usr/lib/xgc2-sensing/libxgc2-sensing-gpu.so
for library in /opt/xgc2/xsim/bin/xsim /usr/lib/xgc2-sensing/libxgc2-sensing-gpu.so; do
  resolved="$(readlink -e -- "$library")"
  test -f "$resolved"
  dependencies="$(ldd "$resolved")"
  if grep -F 'not found' <<<"$dependencies"; then exit 1; fi
done
/opt/xgc2/xsim/bin/xsim --help >/dev/null
EOF

FROM ${AGENT_INSTALL}-agent
