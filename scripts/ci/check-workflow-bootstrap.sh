#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${1:-.}"
exec python3 "${here}/check-workflow-bootstrap.py" "${root}"
