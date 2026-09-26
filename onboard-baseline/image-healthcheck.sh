#!/usr/bin/env bash
set -euo pipefail
profile="${ONBOARD_BASELINE_PROFILE:?}"
/opt/xgc2/onboard-baseline/onboard-baseline.sh check --profile "$profile"
# shellcheck disable=SC1091
source "/opt/ros/${ROS_DISTRO}/setup.bash"
test "$(rosversion -d)" = "${ROS_DISTRO}"
test -x /usr/lib/xgc2/xgc-agent
test -f /lib/systemd/system/xgc2-agent.service
if [[ ! -d /run/systemd/system ]]; then
  pgrep -x xgc-agent >/dev/null
fi
