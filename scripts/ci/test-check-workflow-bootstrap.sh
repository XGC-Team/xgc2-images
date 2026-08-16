#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${here}/../.." && pwd)"
checker="${repo}/scripts/ci/check-workflow-bootstrap.py"
fail=0

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

pass_dir="${tmpdir}/pass/.github/workflows"
fail_dir="${tmpdir}/fail/.github/workflows"
upstream_dir="${tmpdir}/upstream/.github/workflows"
mkdir -p \
  "${pass_dir}" \
  "${fail_dir}" \
  "${upstream_dir}" \
  "${tmpdir}/pass/.xgc2/scripts" \
  "${tmpdir}/fail/.xgc2/scripts" \
  "${tmpdir}/upstream/.xgc2/scripts" \
  "${tmpdir}/fail/manifest"

cat >"${pass_dir}/ci.yml" <<'EOF'
name: ok
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    container: ghcr.io/xgc-team/xgc2-images/xgc2-build-noble-dev:1.0.0
    steps:
      - uses: actions/checkout@v4
      - run: pnpm install --frozen-lockfile
      - run: npm ci
      - run: uv sync --frozen
      - run: apt-get install -y ./debs/xgc2-foo_*.deb
      - run: apt-get install -f
      - run: apt-get install -y --no-install-recommends xgc2-acados libxgc2-math-dev ros-noetic-xgc2-ros1-utils
      - run: apt-get install -y --no-install-recommends ros-melodic-swarm-ros-bridge ros-noetic-scout-msgs
EOF

cat >"${tmpdir}/pass/.xgc2/scripts/build_debs_in_docker.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DOCKER_IMAGE="ghcr.io/xgc-team/xgc2-images/xgc2-build-noble-dev:1.0.0"
apt-get install -y /workspace/out/xgc2-test_1.0.0_amd64.deb
EOF

cat >"${fail_dir}/ci.yml" <<'EOF'
name: bad
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/setup-node@v4
      - run: sudo apt-get install -y cmake
      - run: apt-get install -y xgc2-acados cmake
      - run: apt-get install -y ros-noetic-roscpp
      - run: curl --proto "=https" -sSf https://sh.rustup.rs | sh -s -- -y
EOF

cat >"${tmpdir}/fail/.xgc2/scripts/build_debs_in_docker.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
curl -fsSL https://go.dev/dl/go1.26.2.linux-amd64.tar.gz -o /tmp/go.tgz
EOF

cat >"${tmpdir}/fail/manifest/build.yaml" <<'EOF'
docker_image: ros:noetic-ros-base-focal
EOF

cat >"${upstream_dir}/ci.yml" <<'EOF'
name: upstream
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    container: ghcr.io/xgc-team/xgc2-images/xgc2-build-noble-full-jazzy:1.0.0
EOF

cat >"${tmpdir}/upstream/.xgc2/product.yml" <<'EOF'
schema: xgc2.product.v1
id: xgc2-px4-sitl-116
EOF

cat >"${tmpdir}/upstream/.xgc2/scripts/build_runtime_deb_in_docker.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
apt-get install -y build-essential
bash "${PX4_DIR}/Tools/setup/ubuntu.sh" --no-nuttx
EOF

if ! python3 "${checker}" "${tmpdir}/pass"; then
  echo "expected pass fixture to succeed" >&2
  fail=1
fi
if python3 "${checker}" "${tmpdir}/fail"; then
  echo "expected fail fixture to fail" >&2
  fail=1
fi
if ! python3 "${checker}" "${tmpdir}/upstream"; then
  echo "expected registered upstream fixture to succeed" >&2
  fail=1
fi
printf '%s\n' 'python3 -m pip install -r Tools/setup/requirements.txt' \
  >>"${tmpdir}/upstream/.xgc2/scripts/build_runtime_deb_in_docker.sh"
if python3 "${checker}" "${tmpdir}/upstream"; then
  echo "expected direct pip bootstrap in registered product to fail" >&2
  fail=1
fi

echo "checker fixtures ok"
exit "${fail}"
