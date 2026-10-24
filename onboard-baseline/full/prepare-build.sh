#!/usr/bin/env bash
# Third-party build prerequisites only. Never adds an XGC2 APT source.
set -euo pipefail
. /etc/os-release
if grep -R -E 'xgc2\.apt|xgc2-apt' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
  echo 'The source builder must not resolve products through XGC2 APT.' >&2; exit 1
fi
export DEBIAN_FRONTEND=noninteractive
# Apply transport changes only inside the disposable builder, never on the host.
python3 - <<'TRANSPORT'
from pathlib import Path
for path in [Path('/etc/apt/sources.list'), *Path('/etc/apt/sources.list.d').glob('*.list')]:
    if path.is_file():
        text = path.read_text()
        for host in ('archive.ubuntu.com', 'security.ubuntu.com'):
            text = text.replace('http://'+host+'/ubuntu', 'https://'+host+'/ubuntu')
        path.write_text(text)
TRANSPORT
apt-get update
apt-get install -y --no-install-recommends --no-remove libssl-dev libc-ares-dev zlib1g-dev libjsoncpp-dev \
  python3-yaml python3-protobuf python3-jsonschema libglfw3-dev libglm-dev \
  "ros-$ROS_DISTRO-mavros-msgs" "ros-$ROS_DISTRO-message-generation"
if [[ "$VERSION_CODENAME" == focal ]]; then
  apt-get install -y --no-install-recommends --no-remove libgrpc++-dev protobuf-compiler-grpc protobuf-compiler nlohmann-json3-dev
elif [[ "$VERSION_CODENAME" == bionic ]]; then
  # The product requires HTTP/Boost >=1.70 and gRPC >=1.16. Bionic's stock
  # versions are too old; supply third-party source dependencies in this
  # isolated builder without substituting Focal binaries or changing ROS.
  apt-get install -y --no-install-recommends --no-remove gcc-8 g++-8
  pip3 install --no-input cmake==3.22.6 jsonschema==3.2.0 protobuf==3.19.6 catkin_pkg==0.4.23
  mkdir -p /work/thirdparty /opt/xgc2/thirdparty/include
  cd /work/downloads
  if ! echo '83bfc1507731a0906e387fc28b7ef5417d591429e51e788417fe9ff025e116b1  boost.tar.bz2' | sha256sum -c - >/dev/null 2>&1; then
    curl -fsSL --retry 3 https://archives.boost.io/release/1.74.0/source/boost_1_74_0.tar.bz2 -o boost.tar.bz2
  fi
  echo '83bfc1507731a0906e387fc28b7ef5417d591429e51e788417fe9ff025e116b1  boost.tar.bz2' | sha256sum -c -
  tar -xf boost.tar.bz2 -C /work/thirdparty
  cp -a /work/thirdparty/boost_1_74_0/boost /opt/xgc2/thirdparty/include/
  if ! echo '0d8ef5af7f9794e3263480193c491549b2ba6cc74bb018906202ada498a79406  json.tar.gz' | sha256sum -c - >/dev/null 2>&1; then
    curl -fsSL --retry 3 https://codeload.github.com/nlohmann/json/tar.gz/refs/tags/v3.11.3 -o json.tar.gz
  fi
  echo '0d8ef5af7f9794e3263480193c491549b2ba6cc74bb018906202ada498a79406  json.tar.gz' | sha256sum -c -
  tar -xf json.tar.gz -C /work/thirdparty
  cmake -S /work/thirdparty/json-3.11.3 -B /work/json-build -DJSON_BuildTests=OFF -DCMAKE_INSTALL_PREFIX=/opt/xgc2/thirdparty
  cmake --install /work/json-build
  grpc_source=/work/downloads/grpc-1.16.1
  if [[ ! -d "$grpc_source/.git" ]]; then
    git clone --depth 1 --branch v1.16.1 https://github.com/grpc/grpc.git "$grpc_source"
  fi
  git -C "$grpc_source" submodule update --init --depth 1 third_party/protobuf
  ln -s "$grpc_source" /work/thirdparty/grpc
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
  test "$(git -C /work/thirdparty/grpc rev-parse HEAD)" = a933c40e679c5aef7107e7561e827cd12a1008e0
  cmake -S /work/thirdparty/grpc/third_party/protobuf/cmake -B /work/protobuf-thirdparty-build \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/xgc2/thirdparty \
    -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_BUILD_SHARED_LIBS=ON -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  cmake --build /work/protobuf-thirdparty-build --parallel "$BUILD_JOBS"
  cmake --install /work/protobuf-thirdparty-build
  cmake -S /work/thirdparty/grpc -B /work/grpc-build \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/xgc2/thirdparty \
    -DCMAKE_PREFIX_PATH=/opt/xgc2/thirdparty -DBUILD_SHARED_LIBS=ON -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DgRPC_INSTALL=ON -DgRPC_BUILD_TESTS=OFF -DgRPC_PROTOBUF_PROVIDER=package \
    -DgRPC_SSL_PROVIDER=package -DgRPC_ZLIB_PROVIDER=package -DgRPC_CARES_PROVIDER=package
  cmake --build /work/grpc-build --parallel "$BUILD_JOBS"
  cmake --install /work/grpc-build
  # This upstream CMake generation does not install pkg-config discovery files.
  # Describe the libraries just built, using the version from their own source.
  grpc_version="$(awk '$1 == "set(PACKAGE_VERSION" {gsub(/["()]/,"",$2); print $2; exit}' /work/thirdparty/grpc/CMakeLists.txt)"
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
else
  echo "Unsupported robot source distribution: $VERSION_CODENAME" >&2; exit 2
fi
rm -rf /var/lib/apt/lists/*
