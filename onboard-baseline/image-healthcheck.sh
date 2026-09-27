#!/usr/bin/env bash
set -euo pipefail
profile="${ONBOARD_BASELINE_PROFILE:?}"
# The shared check loads ROS and validates this image's runtime dependencies.
# Agent installation and Core registration belong to the powered environment.
exec /opt/xgc2/onboard-baseline/onboard-baseline.sh check --profile "$profile"
