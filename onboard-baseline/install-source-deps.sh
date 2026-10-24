#!/usr/bin/env bash
# Third-party toolchains and SDKs shared by CI images and real robot preparation.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. /etc/os-release
export BUILD_JOBS="${ONBOARD_BASELINE_JOBS:-2}"
export CARGO_BUILD_JOBS="$BUILD_JOBS"
export RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
export UV_PYTHON_INSTALL_DIR=/usr/local/share/uv/python
export PATH="/usr/local/go/bin:/usr/local/cargo/bin:$PATH"
toolchains="$ROOT/install-toolchains.sh"
[[ -f "$toolchains" ]] || toolchains="$ROOT/../scripts/build/install-toolchains.sh"
if [[ "${1:-apply}" == check ]]; then
  /usr/local/go/bin/go version
  /usr/local/bin/uv --version
  rustc --version
  cmake --version | head -1
  PYTHONDONTWRITEBYTECODE=1 python3 -B -c 'import casadi, deprecated; print("CasADi",casadi.__version__)'
  if [[ "$ONBOARD_BASELINE_PROFILE" != wheeltec-bionic-melodic ]]; then
    test -s /opt/xgc2/thirdparty/acados-native/lib/libacados.so
    test -x /opt/xgc2/thirdparty/acados-native/bin/t_renderer
  fi
  if [[ "$VERSION_CODENAME" == bionic ]]; then
    test -e /opt/xgc2/thirdparty/lib/libgrpc++.so
  fi
  exit 0
fi
cache=/var/cache/xgc2-onboard
mkdir -p "$cache/downloads" "$cache/thirdparty"
# Baseline owns environment installation; a repeat apply reuses installed tools.
if [[ ! -x /usr/local/go/bin/go || ! -x /usr/local/bin/uv || ! -x /usr/local/cargo/bin/cargo ]] || ! python3 -c 'import casadi, deprecated' >/dev/null 2>&1; then
  bash "$toolchains" onboard-build
fi
if [[ "$(cmake --version | head -1)" != 'cmake version 3.22.6' ]]; then
  pip3 install --no-input cmake==3.22.6
fi
cat >/etc/profile.d/xgc-onboard-tools.sh <<'PROFILE'
export RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
export PATH="/usr/local/go/bin:/usr/local/cargo/bin:$PATH"
PROFILE
if [[ "$VERSION_CODENAME" == bionic && ! -f /opt/xgc2/thirdparty/lib/libgrpc++.so ]]; then
  pip3 install --no-input cmake==3.22.6 jsonschema==3.2.0 protobuf==3.19.6 catkin_pkg==0.4.23
  mkdir -p "$cache/thirdparty" /opt/xgc2/thirdparty/include
  cd "$cache/downloads"
  if ! echo '83bfc1507731a0906e387fc28b7ef5417d591429e51e788417fe9ff025e116b1  boost.tar.bz2' | sha256sum -c - >/dev/null 2>&1; then
    curl -fsSL --retry 3 https://archives.boost.io/release/1.74.0/source/boost_1_74_0.tar.bz2 -o boost.tar.bz2
  fi
  echo '83bfc1507731a0906e387fc28b7ef5417d591429e51e788417fe9ff025e116b1  boost.tar.bz2' | sha256sum -c -
  tar -xf boost.tar.bz2 -C $cache/thirdparty
  cp -a "$cache/thirdparty/boost_1_74_0/boost" /opt/xgc2/thirdparty/include/
  if ! echo '0d8ef5af7f9794e3263480193c491549b2ba6cc74bb018906202ada498a79406  json.tar.gz' | sha256sum -c - >/dev/null 2>&1; then
    curl -fsSL --retry 3 https://codeload.github.com/nlohmann/json/tar.gz/refs/tags/v3.11.3 -o json.tar.gz
  fi
  echo '0d8ef5af7f9794e3263480193c491549b2ba6cc74bb018906202ada498a79406  json.tar.gz' | sha256sum -c -
  tar -xf json.tar.gz -C $cache/thirdparty
  cmake -S "$cache/thirdparty/json-3.11.3" -B "$cache/json-build" -DJSON_BuildTests=OFF -DCMAKE_INSTALL_PREFIX=/opt/xgc2/thirdparty
  cmake --install $cache/json-build
  grpc_source="$cache/downloads/grpc-1.16.1"
  if [[ ! -d "$grpc_source/.git" ]]; then
    git clone --depth 1 --branch v1.16.1 https://github.com/grpc/grpc.git "$grpc_source"
  fi
  git -C "$grpc_source" submodule update --init --depth 1 third_party/protobuf
  ln -sfn "$grpc_source" "$cache/thirdparty/grpc"
  # Ubuntu's c-ares development package has headers/library, but no CMake config.
  # Adapt discovery for upstream gRPC without replacing the actual system library.
  mkdir -p /opt/xgc2/thirdparty/lib/cmake/c-ares
  cat > /opt/xgc2/thirdparty/lib/cmake/c-ares/c-aresConfig.cmake <<'CMAKE'
find_path(c-ares_INCLUDE_DIR ares.h REQUIRED)
find_library(c-ares_LIBRARY cares REQUIRED)
if(NOT TARGET c-ares::cares)
  add_library(c-ares::cares UNKNOWN IMPORTED)
  set_target_properties(c-ares::cares PROPERTIES IMPORTED_LOCATION "${c-ares_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${c-ares_INCLUDE_DIR}")
endif()
set(c-ares_FOUND TRUE)
CMAKE
  export LD_LIBRARY_PATH="/opt/xgc2/thirdparty/lib:${LD_LIBRARY_PATH:-}"
  test "$(git -C "$cache/thirdparty/grpc" rev-parse HEAD)" = a933c40e679c5aef7107e7561e827cd12a1008e0
  cmake -S "$cache/thirdparty/grpc/third_party/protobuf/cmake" -B "$cache/protobuf-build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/xgc2/thirdparty \
    -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_BUILD_SHARED_LIBS=ON -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  cmake --build "$cache/protobuf-build" --parallel "$BUILD_JOBS"
  cmake --install $cache/protobuf-build
  cmake -S "$cache/thirdparty/grpc" -B "$cache/grpc-build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/xgc2/thirdparty \
    -DCMAKE_PREFIX_PATH=/opt/xgc2/thirdparty -DBUILD_SHARED_LIBS=ON -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DgRPC_INSTALL=ON -DgRPC_BUILD_TESTS=OFF -DgRPC_PROTOBUF_PROVIDER=package \
    -DgRPC_SSL_PROVIDER=package -DgRPC_ZLIB_PROVIDER=package -DgRPC_CARES_PROVIDER=package
  cmake --build "$cache/grpc-build" --parallel "$BUILD_JOBS"
  cmake --install $cache/grpc-build
  # This upstream CMake generation does not install pkg-config discovery files.
  # Describe the libraries just built, using the version from their own source.
  grpc_version="$(awk '$1 == "set(PACKAGE_VERSION" {gsub(/["()]/,"",$2); print $2; exit}' $cache/thirdparty/grpc/CMakeLists.txt)"
  test -n "$grpc_version"
  mkdir -p /opt/xgc2/thirdparty/lib/pkgconfig
  for component in grpc grpc++ gpr; do
    requires=""
    [[ "$component" != grpc++ ]] || requires="grpc = $grpc_version"
    cat > "/opt/xgc2/thirdparty/lib/pkgconfig/$component.pc" <<PC
prefix=/opt/xgc2/thirdparty
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: $component
Description: Source-built upstream gRPC component
Version: $grpc_version
Requires: $requires
Libs: -L\${libdir} -l$component
Cflags: -I\${includedir}
PC
  done
fi
# Build only the pinned upstream acados SDK. Current first-party staging and
# discovery glue still comes from the local source during product compilation.
if [[ "${ONBOARD_BASELINE_PROFILE}" != wheeltec-bionic-melodic && ! -f /opt/xgc2/thirdparty/acados-native/lib/libacados.so ]]; then
  read -r repository revision < <(python3 - "$ROOT/baselines.json" <<'PYTHON'
import json, sys
value=json.load(open(sys.argv[1]))['thirdParty']
print(value['acadosRecipeRepository'],value['acadosRecipeRevision'])
PYTHON
)
  recipe="$cache/acados-recipe"
  mkdir -p "$recipe"
  curl -fsSL --retry 3 "$repository/archive/$revision.tar.gz" -o "$cache/acados-recipe.tar.gz"
  tar -xzf "$cache/acados-recipe.tar.gz" -C "$recipe" --strip-components=1
  # Portable third-party kernel: works on CI ARM64 hosts and robot ARM64 CPUs.
  sed -i 's/^BLASFEO_TARGET=.*/BLASFEO_TARGET=GENERIC/' "$recipe/acados.lock"
  XGC2_ACADOS_PREFIX=/opt/xgc2/thirdparty/acados-native XGC2_ACADOS_STAGE_DIR="$cache/acados-stage" \
    XGC2_ACADOS_BUILD_DIR="$cache/acados-build" XGC2_ACADOS_SOURCE_CACHE="$cache/acados-source" \
    ACADOS_VENDOR_JOBS="$BUILD_JOBS" bash "$recipe/.xgc2/scripts/build_acados.sh"
  mkdir -p /opt/xgc2/thirdparty
  cp -a "$cache/acados-stage/opt/xgc2/thirdparty/acados-native" /opt/xgc2/thirdparty/
  printf '%s\n' /opt/xgc2/thirdparty/acados-native/lib >/etc/ld.so.conf.d/onboard-acados-native.conf
  ldconfig
fi
