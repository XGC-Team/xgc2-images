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
mkdir -p "${pass_dir}" "${fail_dir}"

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
      - run: curl --proto "=https" -sSf https://sh.rustup.rs | sh -s -- -y
EOF

if ! python3 "${checker}" "${tmpdir}/pass"; then
  echo "expected pass fixture to succeed" >&2
  fail=1
fi
if python3 "${checker}" "${tmpdir}/fail"; then
  echo "expected fail fixture to fail" >&2
  fail=1
fi

echo "checker fixtures ok"
exit "${fail}"
