#!/usr/bin/env bash
# Current baseline contract: no product installation and no host mutation.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash -n "$root/onboard-baseline.sh"
bash -n "$root/build-local-image.sh"
python3 -m unittest discover -s "$root/tests" -p test_baseline.py -v
python3 -m unittest discover -s "$root/tests" -p test_base_boundary.py -v
