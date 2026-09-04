#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

grep -q 'latexmk' "$root/scripts/healthcheck.sh"
grep -q 'xelatex' "$root/scripts/healthcheck.sh"
grep -q 'synctex' "$root/scripts/healthcheck.sh"
grep -q 'XGC2 product packages must not' "$root/scripts/healthcheck.sh"
grep -q 'xgc2-build-noble-base' "$root/Dockerfile"
grep -q 'xgc2-build-assert-no-xgc2-apt.sh' "$root/Dockerfile"
grep -q -- '--network=none' "$root/Dockerfile"
if grep -q 'docker.sock' "$root/docker-compose.yml" "$root/Dockerfile"; then
  echo "definition must not mention docker.sock" >&2
  exit 1
fi
if grep -E 'apt-get install[^\n]*xgc2-' "$root/Dockerfile"; then
  echo "Dockerfile must not install xgc2 APT packages" >&2
  exit 1
fi
echo "xgc2-latex-toolchain definition ok"
