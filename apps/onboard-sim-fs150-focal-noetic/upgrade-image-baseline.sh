#!/usr/bin/env bash
# Update declared pinned interfaces on an immutable role base, then check the
# complete current contract. Never bootstrap ROS/toolchains or start services.
set -euo pipefail
root=/opt/xgc2/onboard-baseline
case "${ONBOARD_IMAGE_ROLE:?}" in
  runtime) declarations=("$root/runtime-packages.txt") ;;
  builder) declarations=("$root/runtime-packages.txt" "$root/builder-packages.txt") ;;
  *) echo 'Unknown image role' >&2; exit 2 ;;
esac
id "$ONBOARD_BASELINE_USER" >/dev/null
test -x /usr/sbin/policy-rc.d
chmod 0755 "$root"/*.sh
"$root/configure-product-apt.sh" https://xgc2.apt.xiaokang.ink focal
apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/xgc2.list -o Dir::Etc::sourceparts=-
# ROS1 Tools consumes the distro Babel Fish library in both image roles. The
# immutable older role bases may predate it; resolve it from the ROS owner only
# when missing, without rebuilding it or upgrading unrelated packages.
if [[ "$(dpkg-query -W -f='${db:Status-Status}' ros-noetic-ros-babel-fish 2>/dev/null || true)" != installed ]]; then
  apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/ros1-snapshots.list -o Dir::Etc::sourceparts=-
  apt-get install -y --no-install-recommends --no-remove ros-noetic-ros-babel-fish
fi
awk -F= 'NF == 2 && $0 !~ /^[[:space:]]*#/ {print}' "${declarations[@]}" |
  xargs -r apt-get install -y --no-install-recommends --no-remove
# Check every role declaration, including unpinned OS dependencies retained in
# the immutable base. Presence does not silently stand in for an exact pin.
for declaration in "${declarations[@]}"; do
  while IFS= read -r specification; do
    [[ -z "$specification" || "$specification" == \#* ]] && continue
    package="${specification%%=*}"
    actual="$(dpkg-query -W -f='${db:Status-Status} ${Version}' "$package")"
    [[ "$actual" == installed\ * ]] || { echo "Missing $package" >&2; exit 1; }
    if [[ "$specification" == *=* && "${actual#installed }" != "${specification#*=}" ]]; then
      echo "Unexpected $package version: $actual" >&2; exit 1
    fi
  done < "$declaration"
done
install -D -m 0755 "$root/install-zenoh.sh" /usr/local/lib/xgc2/zenoh-baseline/install-zenoh.sh
if [[ "$ONBOARD_IMAGE_ROLE" == builder ]]; then
  runuser -u "$ONBOARD_BASELINE_USER" -- "$root/onboard-baseline.sh" check --profile "$ONBOARD_BASELINE_PROFILE"
fi
"$root/check-image.sh"
"$root/assert-base-only.sh"
rm -rf /var/lib/apt/lists/*
