# syntax=docker/dockerfile:1.7
# Stable, formally released role bases preserve their existing dependency layers.
ARG FS150_RUNTIME_BASE=ghcr.io/xgc-team/xgc2-images/onboard-sim-fs150-focal-noetic:runtime-1.0.7@sha256:524b29d2aaeeb7d14482fca4eb9e0db32587c8f0303b354695ff8aeba6cfbbea
ARG FS150_BUILDER_BASE=ghcr.io/xgc-team/xgc2-images/onboard-sim-fs150-focal-noetic:builder-1.0.7@sha256:7cd64e8c8b369c4cb25a40bbbe42745ee073ba961961365193b5bdd68a267f57
FROM scratch AS runtime-sources
COPY --from=tool-scripts onboard-baseline/baselines.json /onboard-baseline/baselines.json
COPY --from=tool-scripts onboard-baseline/onboard-baseline.sh /onboard-baseline/onboard-baseline.sh
COPY --from=tool-scripts onboard-baseline/configure-ubuntu-mirror.sh /onboard-baseline/configure-ubuntu-mirror.sh
COPY --from=tool-scripts onboard-baseline/prepare-apt.sh /onboard-baseline/prepare-apt.sh
COPY --from=tool-scripts onboard-baseline/configure-product-apt.sh /onboard-baseline/configure-product-apt.sh
COPY --from=tool-scripts onboard-baseline/install-source-deps.sh /onboard-baseline/install-source-deps.sh
COPY --from=tool-scripts onboard-baseline/install-zenoh.sh /onboard-baseline/install-zenoh.sh
COPY apps/onboard-sim-fs150-focal-noetic/disable-image-chrony.sh /onboard-baseline/disable-image-chrony.sh
COPY --from=tool-scripts scripts/build/install-toolchains.sh /onboard-baseline/install-toolchains.sh
COPY onboard-baseline/image-healthcheck.sh /onboard-baseline/image-healthcheck.sh
COPY onboard-baseline/assert-base-only.sh /onboard-baseline/assert-base-only.sh
COPY --from=tool-scripts scripts/build/install-ros-apt-source.sh /onboard-baseline/install-ros-apt-source.sh

COPY apps/onboard-sim-fs150-focal-noetic/simulation-packages/ /onboard-baseline/simulation-packages/
COPY apps/onboard-sim-fs150-focal-noetic/runtime-packages.txt /onboard-baseline/runtime-packages.txt
COPY apps/onboard-sim-fs150-focal-noetic/builder-packages.txt /onboard-baseline/builder-packages.txt
COPY apps/onboard-sim-fs150-focal-noetic/check-simulation.sh /onboard-baseline/check-simulation.sh
COPY apps/onboard-sim-fs150-focal-noetic/check-image.sh /onboard-baseline/check-image.sh
COPY apps/onboard-sim-fs150-focal-noetic/check-mavros-vision-plugin.py /onboard-baseline/check-mavros-vision-plugin.py
COPY apps/onboard-sim-fs150-focal-noetic/check-network-databases.sh /onboard-baseline/check-network-databases.sh
COPY apps/onboard-sim-fs150-focal-noetic/upgrade-image-baseline.sh /onboard-baseline/upgrade-image-baseline.sh

FROM ${FS150_RUNTIME_BASE} AS runtime
ENV DEBIAN_FRONTEND=noninteractive ONBOARD_BASELINE_PROFILE=fs150-focal-noetic ONBOARD_BASELINE_USER=marvsmart ONBOARD_IMAGE_ROLE=runtime
COPY --from=runtime-sources /onboard-baseline/ /opt/xgc2/onboard-baseline/
RUN bash /opt/xgc2/onboard-baseline/upgrade-image-baseline.sh
LABEL org.opencontainers.image.version="1.0.17"
ENTRYPOINT ["/ros_entrypoint.sh"]
CMD ["bash"]

FROM ${FS150_BUILDER_BASE} AS builder
ENV DEBIAN_FRONTEND=noninteractive ONBOARD_BASELINE_PROFILE=fs150-focal-noetic ONBOARD_BASELINE_USER=marvsmart ONBOARD_IMAGE_ROLE=builder
COPY --from=runtime-sources /onboard-baseline/ /opt/xgc2/onboard-baseline/
RUN bash /opt/xgc2/onboard-baseline/upgrade-image-baseline.sh
LABEL org.opencontainers.image.version="1.0.17"
ENTRYPOINT ["/ros_entrypoint.sh"]
CMD ["bash"]
