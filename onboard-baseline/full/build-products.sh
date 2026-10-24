#!/usr/bin/env bash
# Composition only: dependency order and standard CMake/install invocation.
# Product-specific generation, compilation and packaging remain product-owned.
set -euo pipefail
. /etc/os-release
ros_prefix="/opt/ros/$ROS_DISTRO"
export BUILD_JOBS="${BUILD_JOBS:-2}"
export CMAKE_PREFIX_PATH="/usr/local:/opt/xgc2/thirdparty:$ros_prefix"
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/opt/xgc2/thirdparty/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="/usr/local/lib:/opt/xgc2/thirdparty/lib:$ros_prefix/lib:${LD_LIBRARY_PATH:-}"
export PATH="/opt/xgc2/thirdparty/bin:/usr/local/go/bin:$PATH"
mkdir -p /out/rootfs /work
python3 /recipe/normalize-inputs.py
if [[ "$VERSION_CODENAME" == bionic ]]; then
  export CC=gcc-8 CXX=g++-8
  mkdir -p /out/rootfs/opt/xgc2/thirdparty
  cp -a /opt/xgc2/thirdparty/lib /out/rootfs/opt/xgc2/thirdparty/
  export XGC2_XSIM_PYTHON="$(find /usr/local/share/uv/python -path '*/bin/python3.12' -print -quit)"
  test -x "$XGC2_XSIM_PYTHON"
fi
merge() {
  # Preserve the distribution's ROS setup, not a temporary catkin workspace's setup.
  for file in _setup_util.py env.sh setup.bash setup.sh setup.zsh local_setup.bash local_setup.sh local_setup.zsh .catkin .rosinstall; do
    rm -f "/out/rootfs$ros_prefix/$file"
  done
  # Debian payloads may spell systemd units under /lib while the selected
  # distribution uses merged-/usr. Normalize only our disposable install root.
  for alias in bin sbin lib lib64; do
    if [[ -L "/$alias" && -d "/out/rootfs/$alias" && ! -L "/out/rootfs/$alias" ]]; then
      target="$(readlink -f "/$alias")"
      mkdir -p "/out/rootfs$target"
      cp -a "/out/rootfs/$alias/." "/out/rootfs$target/"
      rm -rf "/out/rootfs/$alias"
    fi
  done
  cp -a /out/rootfs/. /
  ldconfig
}
cmake_product() {
  local path="$1" name="$2" prefix="$3"
  shift 3
  cmake -S "/source/products/$path" -B "/work/$name" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_TESTING=OFF -DCATKIN_ENABLE_TESTING=OFF \
    -DCATKIN_DEVEL_PREFIX="/work/devel/$name" "$@"
  cmake --build "/work/$name" --parallel "$BUILD_JOBS"
  DESTDIR=/out/rootfs cmake --install "/work/$name"
  merge
}
has() { [[ ",$FULL_COMPONENTS," == *",$1,"* ]]; }
set +u
. "$ros_prefix/setup.bash"
set -u
export CMAKE_PREFIX_PATH="/usr/local:/opt/xgc2/thirdparty:$ros_prefix"
export XGC2_MATH_INCLUDE=/usr/local/include
if has xsim || has adapter || has controller; then
  cmake_product common/math math /usr/local -DXGC2_MATH_BUILD_TESTING=OFF
  cmake_product common/state-machine state-machine /usr/local -DXGC2_STATE_MACHINE_BUILD_TESTING=OFF
  cmake_product common/xrpc xrpc /usr/local '-DXGC2_XRPC_COMPONENTS=http;bootstrap;grpc;udp'
  # Build the source-owned schema registry, rather than downloading a schema deb.
  /source/products/common/protobuf/.xgc2/scripts/install_source.sh /work/protobuf /out/rootfs
  merge
  for package in xgc2_geometry_msgs ugv_reset_msgs; do
    cmake_product "ros1/common/ros1-msgs/$package" "$package" "$ros_prefix"
  done
fi
if has xsim; then
  cmake_product common/chassis-hold chassis-hold /usr/local
  /source/products/ros1/simulator/xsim/.xgc2/scripts/build_source.sh \
    /work/xsim /out/rootfs /source/products/ros1/simulator/gazebo-sim/fs150-sitl
  merge
fi
if has adapter; then
  /source/products/ros1/communication/ros1-adapter/.xgc2/scripts/build_source.sh \
    /work/adapters /out/rootfs "$ros_prefix" common
  merge
  selection=ugv
  [[ "$ONBOARD_BASELINE_PROFILE" != fs150-focal-noetic ]] || selection=px4
  /source/products/ros1/communication/ros1-adapter/.xgc2/scripts/build_source.sh \
    /work/adapters /out/rootfs "$ros_prefix" "$selection"
  merge
fi
if has controller; then
  if [[ "$ONBOARD_BASELINE_PROFILE" != wheeltec-bionic-melodic ]]; then
    # The acados owner fetches its locked third-party sources, builds and stages them.
    acados_key="$(sha256sum /source/products/common/acados/acados.lock /source/products/common/acados/.xgc2/scripts/build_acados.sh /source/products/common/acados/.xgc2/scripts/fetch_acados.sh /source/products/common/acados/.xgc2/scripts/build_t_renderer.sh | sha256sum | cut -d' ' -f1)"
    if [[ ! -s /work/acados-stage/opt/xgc2/acados/lib/libacados.so || "$(cat /work/acados-source-key 2>/dev/null || true)" != "$acados_key" ]]; then
      XGC2_ACADOS_STAGE_DIR=/work/acados-stage XGC2_ACADOS_BUILD_DIR=/work/acados-build \
        XGC2_ACADOS_SOURCE_CACHE=/work/acados-source ACADOS_VENDOR_JOBS="$BUILD_JOBS" \
        /source/products/common/acados/.xgc2/scripts/build_acados.sh
      printf '%s\n' "$acados_key" > /work/acados-source-key
    fi
    rm -rf /work/acados-sdk
    PACKAGE_DISTRIBUTION="$VERSION_CODENAME" \
      /source/products/common/acados/.xgc2/scripts/stage_sdk.sh /work/acados-stage /work/acados-sdk
    cp -a /work/acados-sdk/. /
    /source/products/common/acados/.xgc2/scripts/stage_runtime.sh /work/acados-stage /out/rootfs
    merge
    export LD_LIBRARY_PATH="/opt/xgc2/acados/lib:$LD_LIBRARY_PATH"
  fi
  for package in state_machine_msgs rigid_state_estimator_msgs hover_thrust_estimator_msgs multirotor_reference_trajectory_msgs px4_multirotor_controller_msgs unicycle_reference_trajectory_msgs; do
    cmake_product "ros1/common/ros1-msgs/$package" "$package" "$ros_prefix"
  done
  cmake_product ros1/common/ros1-utils ros1-utils "$ros_prefix"
  cmake_product ros1/controller/ugv-controller/ugv_reset_client ugv-reset-client "$ros_prefix"
  if [[ "$ONBOARD_BASELINE_PROFILE" == fs150-focal-noetic ]]; then
    cmake_product ros1/perception/estimator/hover-thrust/hover_thrust_estimator hover-thrust "$ros_prefix" -DBUILD_ROS=OFF
    cmake_product ros1/controller/multirotor-controller/px4_multirotor_controller multirotor-controller "$ros_prefix"
  elif [[ "$ONBOARD_BASELINE_PROFILE" == wheeltec-bionic-melodic ]]; then
    cmake_product ros1/controller/ugv-controller/mecanum_ugv_controller mecanum-controller "$ros_prefix"
  else
    cmake_product ros1/controller/ugv-controller/unicycle_ugv_controller unicycle-controller "$ros_prefix"
  fi
fi
# Use the product's normal Agent build, staging, manifest and Debian payload rules.
# Workspace modules supply our code; prohibit a missing local first-party module
# from falling through to a published/private VCS dependency.
export GOPRIVATE='github.com/XGC-Team/*,github.com/xgc-team/*'
export GONOPROXY="$GOPRIVATE" GONOSUMDB="$GOPRIVATE"
export GOVCS='github.com/XGC-Team/*:off,github.com/xgc-team/*:off,public:git|hg,private:off'
cd /source
GOWORK=/source/go.work go work init ./products/xgc2/core-xgc ./products/common/agent-runtime ./products/common/storage ./products/common/xrpc/go
export GOWORK=/source/go.work
python3 /recipe/verify-go-sources.py
cd /source/products/xgc2
agent_path="$PATH"
if [[ "$VERSION_CODENAME" == bionic ]]; then
  # Release manifest generation needs modern Python; ROS/code generation keeps
  # the distribution interpreter and its ABI-compatible native Python modules.
  agent_path="$(dirname "$XGC2_XSIM_PYTHON"):$PATH"
fi
PATH="$agent_path" XGC_BUILD_TARGETS="agent:linux/$(dpkg --print-architecture)" XGC_BUILD_FORMATS=deb \
  XGC_VERSION=dev XGC_DEBIAN_VERSION=0~local CGO_ENABLED=0 ./scripts/build.sh
for deb in dist/xgc2-agent_*.deb; do dpkg-deb -x "$deb" /out/rootfs; done
mkdir -p /out/rootfs/etc/ld.so.conf.d
printf '%s\n' /usr/local/lib /opt/xgc2/thirdparty/lib "$ros_prefix/lib" /opt/xgc2/acados/lib \
  > /out/rootfs/etc/ld.so.conf.d/xgc2-full.conf
merge
python3 /recipe/collect-runtime.py
