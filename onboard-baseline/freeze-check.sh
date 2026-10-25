#!/usr/bin/env bash
# Current baseline contract: no product installation and no host mutation.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$root/../scripts/tool-scripts-context.py" --url-only >/dev/null
bash -n "$root/build-local-image.sh"
python3 -m unittest discover -s "$root/tests" -p test_base_boundary.py -v
