#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" != "0" ]]; then
  echo "install-products.sh must run as root" >&2
  exit 1
fi

lock_file="${1:-}"
apt_base_url="${XGC2_APT_BASE_URL:-https://xgc2.apt.xiaokang.ink}"

if [[ -z "${lock_file}" || ! -f "${lock_file}" ]]; then
  echo "usage: install-products.sh PACKAGES_LOCK" >&2
  exit 1
fi

if [[ ! "${apt_base_url}" =~ ^https?:// ]]; then
  echo "XGC2_APT_BASE_URL must be an HTTP(S) URL" >&2
  exit 1
fi

apt_base_url="${apt_base_url%/}"

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates \
  clang-10 \
  curl \
  gosu \
  gstreamer1.0-gl \
  gstreamer1.0-libav \
  gstreamer1.0-plugins-bad \
  gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-ugly \
  iproute2 \
  jq \
  libpulse0 \
  libxcb-cursor0 \
  libxcb-xinerama0 \
  libxkbcommon-x11-0 \
  lsof \
  procps \
  socat \
  sudo \
  tini

install -d -m 0755 /etc/apt/keyrings
curl -fsSL \
  "${apt_base_url}/xgc2-archive-keyring.gpg" \
  -o /etc/apt/keyrings/xgc2-archive-keyring.gpg
chmod 0644 /etc/apt/keyrings/xgc2-archive-keyring.gpg

architecture="$(dpkg --print-architecture)"
cat >/etc/apt/sources.list.d/xgc2.list <<EOF
deb [arch=${architecture} signed-by=/etc/apt/keyrings/xgc2-archive-keyring.gpg] ${apt_base_url} focal main
EOF

mapfile -t packages < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "${lock_file}")
if [[ "${#packages[@]}" -eq 0 ]]; then
  echo "no packages found in ${lock_file}" >&2
  exit 1
fi

apt-get update
apt-get install -y --no-install-recommends "${packages[@]}"

for entry in "${packages[@]}"; do
  package="${entry%%=*}"
  expected_version="${entry#*=}"
  installed_version="$(dpkg-query -W -f='${Version}' "${package}")"
  if [[ "${installed_version}" != "${expected_version}" ]]; then
    echo "${package}: expected ${expected_version}, installed ${installed_version}" >&2
    exit 1
  fi
done

# First-party wheel from the same trusted SDK push as the formal Debian release.
# All third-party Python requirements are owned by the pinned runtime image.
sdk_wheel=/tmp/xgc2_xrpc-0.1.0-py3-none-any.whl
curl -fsSL --retry 5 \
  https://github.com/XGC-Team/xgc2-xrpc/releases/download/v0.1.0-1/xgc2_xrpc-0.1.0-py3-none-any.whl \
  -o "$sdk_wheel"
echo "8e505ab2366eed198dcd4343e758fed5b7936990b2a72ba635d73d81b195187c  $sdk_wheel" | sha256sum -c -
python3 -m pip install --no-index --no-deps "$sdk_wheel"
rm "$sdk_wheel"
