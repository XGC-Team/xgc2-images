#!/usr/bin/env bash
# Install pinned CI toolchains into /usr/local. Apt packages belong in
# packages/*.txt; this script covers binaries Ubuntu does not ship at the
# versions product CI needs (Node, pnpm/yarn via corepack, uv, Go, Rust,
# Bun, gh, buf, skopeo on focal, meson 1.3.2 on focal/jammy, and a pinned
# CasADi for NMPC codegen). Ripgrep is installed in the base layer.
set -euo pipefail

if [[ "$(id -u)" != "0" ]]; then
  echo "install-toolchains.sh must run as root" >&2
  exit 1
fi

. /etc/os-release
codename="${VERSION_CODENAME}"
arch="$(dpkg --print-architecture)"

NODE22_VERSION="22.16.0"
NODE16_VERSION="16.20.2"
PNPM_VERSION="11.21.0"
PNPM_BIONIC_VERSION="8.15.9"
YARN_VERSION="4.17.0"
GO_VERSION="1.26.5"
UV_VERSION="0.9.24"
BUN_VERSION="1.3.13"
GH_VERSION="2.74.2"
BUF_VERSION="1.47.2"
SKOPEO_VERSION="1.20.0"
PYTHON_UV_VERSION="3.12"
RUSTUP_VERSION="1.29.0"
RUST_TOOLCHAIN_VERSION="1.93.0"

declare -A NODE22_SHA=(
  [amd64]=f4cb75bb036f0d0eddf6b79d9596df1aaab9ddccd6a20bf489be5abe9467e84e
  [arm64]=eab80cb88f8fda1e65f5e8d0420c9809bdb320b03fd34976ab7161b6e703b910
)
declare -A NODE16_SHA=(
  [amd64]=874463523f26ed528634580247f403d200ba17a31adf2de98a7b124c6eb33d87
  [arm64]=e88d86154d1ce53dc52fd74d79d4bfdf0b05f58c0bb2639adfa36e9378b770c4
)
declare -A GO_SHA=(
  [amd64]=5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053
  [arm64]=fe4789e92b1f33358680864bbe8704289e7bb5fc207d80623c308935bd696d49
)
declare -A UV_SHA=(
  [amd64]=cf307aa4271038daa334ca64e75aa40c0c085ce6fa0c0e6f21e41a2b62c7904d
  [arm64]=b16359904ede857b90b68168f10b0f6bf500858df9bed4e7156dbc59fd3f0747
)
declare -A BUN_SHA=(
  [amd64]=79c0771fa8b92c33aae41e15a0e0d307ea99d0e2f00317c71c6c53237a78e25a
  [arm64]=70bae41b3908b0a120e1e58c5c8af30e74afae3b8d11b0d3fdd8e787ddfb4b22
)
declare -A GH_SHA=(
  [amd64]=c421091ae5800390e6aef1f50bfda59cc1d4f2ef2200bcd4e1a662c05c28c444
  [arm64]=f0b07f0aeaf00f137df1bd33a76e717b1945f4b83bd6a3296b365414d3eb413f
)
declare -A BUF_SHA=(
  [amd64]=3a0c4da8d46eea8136affa63db202c76a44f8112384160b73c3fffb1cf14b5d8
  [arm64]=47ddd7ac0bb2a29f8c92aa420dd113bed3b6857190976402eec93ab9847270b4
)
declare -A RUSTUP_SHA=(
  [amd64]=4acc9acc76d5079515b46346a485974457b5a79893cfb01112423c89aeb5aa10
  [arm64]=9732d6c5e2a098d3521fca8145d826ae0aaa067ef2385ead08e6feac88fa5792
)
# Static skopeo for Ubuntu 20.04: focal archives do not ship the package.
# Binaries from https://github.com/felipecrs/skopeo-bin (official skopeo
# does not publish Linux assets). jammy/noble install skopeo via apt.
declare -A SKOPEO_SHA=(
  [amd64]=3a07877b6f69ca4d2e8325c41b5d546c4c4a1a9f8337e6021cda9c9485cba232
  [arm64]=53cb7a20907b869322f3c01aa3d0568a11004fd12151db42057a1cd88d58fc19
)

case "${arch}" in
  amd64)
    node_arch=x64
    go_arch=amd64
    uv_arch=x86_64-unknown-linux-musl
    bun_zip=bun-linux-x64.zip
    gh_arch=amd64
    buf_arch=x86_64
    skopeo_bin=skopeo.linux-amd64
    rustup_triple=x86_64-unknown-linux-gnu
    ;;
  arm64)
    node_arch=arm64
    go_arch=arm64
    uv_arch=aarch64-unknown-linux-musl
    bun_zip=bun-linux-aarch64.zip
    gh_arch=arm64
    buf_arch=aarch64
    skopeo_bin=skopeo.linux-arm64
    rustup_triple=aarch64-unknown-linux-gnu
    ;;
  *)
    echo "unsupported architecture: ${arch}" >&2
    exit 1
    ;;
esac

fetch_verify() {
  local url="$1" dest="$2" sha="$3"
  curl -fsSL --retry 5 --retry-delay 2 -o "${dest}" "${url}"
  echo "${sha}  ${dest}" | sha256sum -c -
}

pip_install() {
  local args=(--no-cache-dir)
  if [[ "${codename}" == "noble" ]]; then
    args+=(--break-system-packages)
  fi
  python3 -m pip install "${args[@]}" "$@"
}

install_node() {
  local version sha tarball url
  if [[ "${codename}" == "bionic" ]]; then
    version="${NODE16_VERSION}"
    sha="${NODE16_SHA[${arch}]}"
  else
    version="${NODE22_VERSION}"
    sha="${NODE22_SHA[${arch}]}"
  fi
  tarball="node-v${version}-linux-${node_arch}.tar.xz"
  url="https://nodejs.org/dist/v${version}/${tarball}"
  fetch_verify "${url}" "/tmp/${tarball}" "${sha}"
  tar -xJf "/tmp/${tarball}" -C /usr/local --strip-components=1
  rm -f "/tmp/${tarball}"
  hash -r
  corepack enable
  if [[ "${codename}" == "bionic" ]]; then
    corepack prepare "pnpm@${PNPM_BIONIC_VERSION}" --activate
  else
    corepack prepare "pnpm@${PNPM_VERSION}" --activate
    corepack prepare "yarn@${YARN_VERSION}" --activate
  fi
  node -v
  pnpm -v
}

install_go() {
  local tarball="go${GO_VERSION}.linux-${go_arch}.tar.gz"
  fetch_verify \
    "https://go.dev/dl/${tarball}" \
    "/tmp/${tarball}" \
    "${GO_SHA[${arch}]}"
  rm -rf /usr/local/go
  tar -xzf "/tmp/${tarball}" -C /usr/local
  rm -f "/tmp/${tarball}"
  ln -sfn /usr/local/go/bin/go /usr/local/bin/go
  ln -sfn /usr/local/go/bin/gofmt /usr/local/bin/gofmt
  go version
}

install_uv() {
  local tarball="uv-${uv_arch}.tar.gz"
  fetch_verify \
    "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${tarball}" \
    "/tmp/${tarball}" \
    "${UV_SHA[${arch}]}"
  tar -xzf "/tmp/${tarball}" -C /tmp
  install -m 0755 /tmp/uv-${uv_arch}/uv /usr/local/bin/uv
  if [[ -x /tmp/uv-${uv_arch}/uvx ]]; then
    install -m 0755 /tmp/uv-${uv_arch}/uvx /usr/local/bin/uvx
  fi
  rm -rf "/tmp/${tarball}" "/tmp/uv-${uv_arch}"
  export UV_PYTHON_INSTALL_DIR=/usr/local/share/uv/python
  mkdir -p "${UV_PYTHON_INSTALL_DIR}"
  if [[ "${codename}" != "noble" ]]; then
    uv python install "${PYTHON_UV_VERSION}"
  fi
  uv --version
}

install_rust() {
  export RUSTUP_HOME=/usr/local/rustup
  export CARGO_HOME=/usr/local/cargo
  mkdir -p "${RUSTUP_HOME}" "${CARGO_HOME}"
  fetch_verify \
    "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${rustup_triple}/rustup-init" \
    /tmp/rustup-init \
    "${RUSTUP_SHA[${arch}]}"
  chmod +x /tmp/rustup-init
  /tmp/rustup-init -y --profile minimal \
    --default-toolchain "${RUST_TOOLCHAIN_VERSION}" --no-modify-path
  rm -f /tmp/rustup-init
  chmod -R a+rX "${RUSTUP_HOME}" "${CARGO_HOME}"
  ln -sfn "${CARGO_HOME}/bin/rustc" /usr/local/bin/rustc
  ln -sfn "${CARGO_HOME}/bin/cargo" /usr/local/bin/cargo
  ln -sfn "${CARGO_HOME}/bin/rustup" /usr/local/bin/rustup
  rustc --version
  cargo --version
  test "$(rustc --version | awk '{print $2}')" = "${RUST_TOOLCHAIN_VERSION}"
  test "$(cargo --version | awk '{print $2}')" = "${RUST_TOOLCHAIN_VERSION}"
}

install_bun() {
  if [[ "${codename}" == "bionic" ]]; then
    echo "skipping bun on bionic (glibc too old)"
    return 0
  fi
  fetch_verify \
    "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/${bun_zip}" \
    "/tmp/${bun_zip}" \
    "${BUN_SHA[${arch}]}"
  mkdir -p /tmp/bun-extract
  unzip -q "/tmp/${bun_zip}" -d /tmp/bun-extract
  bun_bin="$(find /tmp/bun-extract -type f -name bun | head -n 1)"
  install -m 0755 "${bun_bin}" /usr/local/bin/bun
  rm -rf "/tmp/${bun_zip}" /tmp/bun-extract
  bun --version
}

install_gh() {
  local tarball="gh_${GH_VERSION}_linux_${gh_arch}.tar.gz"
  fetch_verify \
    "https://github.com/cli/cli/releases/download/v${GH_VERSION}/${tarball}" \
    "/tmp/${tarball}" \
    "${GH_SHA[${arch}]}"
  tar -xzf "/tmp/${tarball}" -C /tmp
  install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${gh_arch}/bin/gh" /usr/local/bin/gh
  rm -rf "/tmp/${tarball}" "/tmp/gh_${GH_VERSION}_linux_${gh_arch}"
  gh --version
}

install_buf() {
  fetch_verify \
    "https://github.com/bufbuild/buf/releases/download/v${BUF_VERSION}/buf-Linux-${buf_arch}" \
    /tmp/buf \
    "${BUF_SHA[${arch}]}"
  install -m 0755 /tmp/buf /usr/local/bin/buf
  rm -f /tmp/buf
  buf --version
}

install_skopeo() {
  if [[ "${codename}" != "focal" ]]; then
    return 0
  fi
  fetch_verify \
    "https://github.com/felipecrs/skopeo-bin/releases/download/v${SKOPEO_VERSION}/${skopeo_bin}" \
    "/tmp/${skopeo_bin}" \
    "${SKOPEO_SHA[${arch}]}"
  install -m 0755 "/tmp/${skopeo_bin}" /usr/local/bin/skopeo
  rm -f "/tmp/${skopeo_bin}"
  mkdir -p /etc/containers
  if [[ ! -f /etc/containers/policy.json ]]; then
    printf '%s\n' '{"default":[{"type":"insecureAcceptAnything"}]}' >/etc/containers/policy.json
  fi
  skopeo --version
}

write_profile() {
  cat >/etc/profile.d/xgc2-dev-toolchain.sh <<'EOF'
export PATH="/usr/local/go/bin:/usr/local/cargo/bin:/usr/local/bin:${PATH}"
export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo
export GOPATH=/work/go
export UV_PYTHON_INSTALL_DIR=/usr/local/share/uv/python
EOF
  chmod 0644 /etc/profile.d/xgc2-dev-toolchain.sh
}

install_node
install_go
install_uv
install_rust
install_bun
install_gh
install_buf
install_meson() {
  # mavlink-router needs meson 1.3; focal/jammy apt ships 0.53/0.61.
  # noble already has 1.3 from apt. bionic stays on archive meson (unused).
  case "${codename}" in
    focal|jammy)
      pip_install "meson==1.3.2"
      ;;
    *)
      return 0
      ;;
  esac
  meson --version
}

install_python_proto_generators() {
  # xgc2-protobuf generate.sh imports grpc_tools.protoc.
  case "${codename}" in
    jammy)
      pip_install "grpcio-tools==1.70.0" "PyYAML==6.0.2"
      python3 -c "import grpc_tools.protoc, yaml"
      ;;
    noble)
      # Ubuntu owns python3-yaml without pip RECORD metadata. Install the
      # pinned wheel in /usr/local without attempting to uninstall the Deb.
      pip_install --ignore-installed "PyYAML==6.0.2"
      pip_install "grpcio-tools==1.70.0"
      python3 -c "import grpc_tools.protoc, yaml"
      ;;
    *)
      return 0
      ;;
  esac
}

# Official CasADi 3.5.5 cp36 wheels. pip index resolution on bionic-arm64
# skips 3.5.5 (it only offers 3.6+), so install by pinned URL like Node/Go.
declare -A CASADI355_WHEEL=(
  [amd64]=https://files.pythonhosted.org/packages/62/55/61a10cad304f80621836b811d70666c06a9c22863768cc23edd6904bb35f/casadi-3.5.5-cp36-none-manylinux1_x86_64.whl
  [arm64]=https://files.pythonhosted.org/packages/cc/fe/15ff5bdfa24cc0e420a7d4e807d2b56c4aced9ec5eb25315a7e48271b88d/casadi-3.5.5-cp36-none-manylinux2014_aarch64.whl
)
declare -A CASADI355_SHA=(
  [amd64]=5f6eb8de31735c14ecc777e3ad77b57767b5f2dbea29265909ef696f51e8be92
  [arm64]=adf20c34ba2cec1840a026023d93cc6d9b3581dfda6a044f434fc75b50c9a2ce
)

install_casadi() {
  # Shared NMPC / acados / controller codegen pin. Bionic stays on 3.5.5
  # because 18.04's Python 3.6 cannot import CasADi 3.7.
  case "${codename}" in
    bionic)
      local wheel_url="${CASADI355_WHEEL[${arch}]}"
      local wheel="/tmp/${wheel_url##*/}"
      # Bionic's pip 9 predates the manylinux2014 tag used by the arm64 wheel.
      pip_install --upgrade "pip==21.3.1"
      fetch_verify "${wheel_url}" "${wheel}" "${CASADI355_SHA[${arch}]}"
      pip_install \
        "${wheel}" "Deprecated==1.2.14" \
        "dataclasses==0.8" "typing_extensions==4.1.1"
      rm -f "${wheel}"
      ;;
    focal|jammy|noble)
      pip_install \
        "casadi==3.7.2" "Deprecated==1.2.14"
      ;;
    *)
      echo "unsupported Ubuntu codename for CasADi: ${codename}" >&2
      exit 1
      ;;
  esac
  python3 -c "import casadi, deprecated; print('casadi', casadi.__version__)"
}

install_skopeo
install_meson
install_python_proto_generators
install_casadi
write_profile
