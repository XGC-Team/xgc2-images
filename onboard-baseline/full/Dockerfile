# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE
ARG BUILD_IMAGE
FROM ${BUILD_IMAGE} AS source-build
ARG BUILD_JOBS=2
ENV BUILD_JOBS=${BUILD_JOBS}
COPY recipe/prepare-build.sh /recipe/prepare-build.sh
# This is the compiler/dependency layer, never the robot runtime base.
RUN --mount=type=cache,target=/root/.cache/pip --mount=type=cache,target=/root/.cache/uv \
    --mount=type=cache,id=xgc2-full-downloads-${ROS_DISTRO},target=/work/downloads,sharing=locked bash /recipe/prepare-build.sh
COPY recipe/ /recipe/
ARG PROFILE
ARG FULL_COMPONENTS
ARG TARGETARCH
ARG BUILD_CACHE_ID
ENV ONBOARD_BASELINE_PROFILE=${PROFILE} FULL_COMPONENTS=${FULL_COMPONENTS}
COPY source/ /source/
RUN --mount=type=cache,id=xgc2-full-${BUILD_CACHE_ID}-${ROS_DISTRO}-${TARGETARCH},target=/work,sharing=locked \
    --mount=type=cache,target=/root/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/root/.cargo/registry --mount=type=cache,target=/root/.cargo/git \
    bash /recipe/build-products.sh

FROM ${BASE_IMAGE}
ARG INPUT_ID
ARG PROFILE
ARG FULL_COMPONENTS
LABEL org.xgc2.robot-full.input=${INPUT_ID} org.xgc2.robot-full.profile=${PROFILE} org.xgc2.robot-full.components=${FULL_COMPONENTS}
COPY --from=source-build /out/runtime-packages.txt /tmp/full-runtime-packages.txt
# Only distro/ROS third-party packages. The clean base has no XGC2 APT source.
RUN /opt/xgc2/onboard-baseline/assert-base-only.sh \
    && sed -i -e 's|http://archive.ubuntu.com/ubuntu|https://archive.ubuntu.com/ubuntu|g' -e 's|http://security.ubuntu.com/ubuntu|https://security.ubuntu.com/ubuntu|g' /etc/apt/sources.list \
    && apt-get update \
    && xargs -r apt-get install -y --no-install-recommends --no-remove < /tmp/full-runtime-packages.txt \
    && rm -rf /var/lib/apt/lists/* /tmp/full-runtime-packages.txt
COPY --from=source-build /out/rootfs/ /
COPY --from=source-build /out/payload.json /usr/local/share/xgc2/full-image/payload.json
COPY inputs.json /usr/local/share/xgc2/full-image/inputs.json
COPY recipe/verify.py /usr/local/share/xgc2/full-image/verify.py
RUN ldconfig && python3 /usr/local/share/xgc2/full-image/verify.py
ENTRYPOINT ["/opt/xgc2/onboard-baseline/image-entrypoint.sh"]
CMD []
