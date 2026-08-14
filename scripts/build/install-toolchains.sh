#!/usr/bin/env bash
# Install pinned CI toolchains into /usr/local. Apt packages belong in
# packages/*.txt; this script covers binaries Ubuntu does not ship at the
# versions product CI needs (Node, pnpm/yarn via corepack, uv, Go, Rust,
# Bun, gh, buf, and ripgrep on distros without it).
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
YARN_VERSION="3.6.3"
GO_VERSION="1.26.5"
UV_VERSION="0.9.24"
BUN_VERSION="1.3.13"
GH_VERSION="2.74.2"
BUF_VERSION="1.47.2"
RG_VERSION="14.1.1"
PYTHON_UV_VERSION="3.12"

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
  [amd64]=5b91a48f0b00df9fd2da8bff1a795d2659d842da966432969203f25da19d1c74
  [arm64]=5385e978107ce4934298d8d6afe9bfbb898683f6cc23e6753a0da60bc60c5b81
)
declare -A GH_SHA=(
  [amd64]=c421091ae5800390e6aef1f50bfda59cc1d4f2ef2200bcd4e1a662c05c28c444
  [arm64]=f0b07f0aeaf00f137df1bd33a76e717b1945f4b83bd6a3296b365414d3eb413f
)
declare -A BUF_SHA=(
  [amd64]=3a0c4da8d46eea8136affa63db202c76a44f8112384160b73c3fffb1cf14b5d8
  [arm64]=47ddd7ac0bb2a29f8c92aa420dd113bed3b6857190976402eec93ab9847270b4
)
declare -A RG_SHA=(
  [amd64]=4cf9f2741e6c465ffdb7c26f38056a59e2a2544b51f7cc128ef28337eeae4d8e
  [arm64]=c827481c4ff4ea10c9dc7a4022c8de5db34a5737cb74484d62eb94a95841ab2f
)

case "${arch}" in
  amd64)
    node_arch=x64
    go_arch=amd64
    uv_arch=x86_64-unknown-linux-musl
    bun_zip=bun-linux-x64-musl.zip
    gh_arch=amd64
    buf_arch=x86_64
    rg_triple=x86_64-unknown-linux-musl
    rustup_triple=x86_64-unknown-linux-gnu
    ;;
  arm64)
    node_arch=arm64
    go_arch=arm64
    uv_arch=aarch64-unknown-linux-musl
    bun_zip=bun-linux-aarch64-musl.zip
    gh_arch=arm64
    buf_arch=aarch64
    rg_triple=aarch64-unknown-linux-gnu
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
  curl -fsSL --retry 5 --retry-delay 2 \
    "https://static.rust-lang.org/rustup/dist/${rustup_triple}/rustup-init" \
    -o /tmp/rustup-init
  chmod +x /tmp/rustup-init
  /tmp/rustup-init -y --profile minimal --default-toolchain stable --no-modify-path
  rm -f /tmp/rustup-init
  chmod -R a+rX "${RUSTUP_HOME}" "${CARGO_HOME}"
  ln -sfn "${CARGO_HOME}/bin/rustc" /usr/local/bin/rustc
  ln -sfn "${CARGO_HOME}/bin/cargo" /usr/local/bin/cargo
  ln -sfn "${CARGO_HOME}/bin/rustup" /usr/local/bin/rustup
  rustc --version
  cargo --version
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

install_ripgrep() {
  if command -v rg >/dev/null 2>&1; then
    rg --version
    return 0
  fi
  local tarball="ripgrep-${RG_VERSION}-${rg_triple}.tar.gz"
  fetch_verify \
    "https://github.com/BurntSushi/ripgrep/releases/download/${RG_VERSION}/${tarball}" \
    "/tmp/${tarball}" \
    "${RG_SHA[${arch}]}"
  tar -xzf "/tmp/${tarball}" -C /tmp
  install -m 0755 "/tmp/ripgrep-${RG_VERSION}-${rg_triple}/rg" /usr/local/bin/rg
  rm -rf "/tmp/${tarball}" "/tmp/ripgrep-${RG_VERSION}-${rg_triple}"
  rg --version
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
install_ripgrep
write_profile
