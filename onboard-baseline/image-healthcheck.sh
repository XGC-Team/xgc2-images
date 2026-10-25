#!/usr/bin/env bash
set -euo pipefail
profile="${ONBOARD_BASELINE_PROFILE:?}"
# Runtime readiness checks the same dependencies as physical setup.
# Base package exclusion is enforced once by the Dockerfile during image creation.
exec /opt/xgc2/onboard-baseline/onboard-baseline.sh check --profile "$profile"
