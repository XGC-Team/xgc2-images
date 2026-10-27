#!/usr/bin/env bash
# Only the container image owns these unit settings; the host provides its clock.
set -euo pipefail
systemctl --root=/ disable chrony.service
systemctl --root=/ mask chrony.service chronyd.service
