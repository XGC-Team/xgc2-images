#!/usr/bin/env bash
# Ensure rg is on PATH in every build image, including base.
# focal/jammy/noble install the distro package first; bionic has no apt
# ripgrep, so this falls back to a pinned GitHub release (same vendor
# pattern as install-toolchains.sh).
set -euo pipefail

if [[ "$(id -u)" != "0" ]]; then
  echo "install-ripgrep.sh must run as root" >&2
  exit 1
fi

RG_VERSION="14.1.1"
arch="$(dpkg --print-architecture)"

declare -A RG_SHA=(
  [amd64]=4cf9f2741e6c465ffdb7c26f38056a59e2a2544b51f7cc128ef28337eeae4d8e
  [arm64]=c827481c4ff4ea10c9dc7a4022c8de5db34a5737cb74484d62eb94a95841ab2f
)
declare -A RG_TRIPLE=(
  [amd64]=x86_64-unknown-linux-musl
  [arm64]=aarch64-unknown-linux-gnu
)

if command -v rg >/dev/null 2>&1; then
  rg --version
  exit 0
fi

triple="${RG_TRIPLE[${arch}]:-}"
sha="${RG_SHA[${arch}]:-}"
if [[ -z "${triple}" || -z "${sha}" ]]; then
  echo "unsupported architecture for ripgrep fallback: ${arch}" >&2
  exit 1
fi

tarball="ripgrep-${RG_VERSION}-${triple}.tar.gz"
dest="/tmp/${tarball}"
curl -fsSL --retry 5 --retry-delay 2 -o "${dest}" \
  "https://github.com/BurntSushi/ripgrep/releases/download/${RG_VERSION}/${tarball}"
echo "${sha}  ${dest}" | sha256sum -c -
tar -xzf "${dest}" -C /tmp
install -m 0755 "/tmp/ripgrep-${RG_VERSION}-${triple}/rg" /usr/local/bin/rg
rm -rf "${dest}" "/tmp/ripgrep-${RG_VERSION}-${triple}"
hash -r
rg --version
