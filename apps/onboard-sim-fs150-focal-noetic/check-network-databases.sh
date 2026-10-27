#!/usr/bin/env bash
# Called as the robot user; VRPN requires the protocol and service databases.
set -euo pipefail
for path in /etc/protocols /etc/services; do
  [[ -r "$path" ]] || { echo "Missing or unreadable network database: $path" >&2; exit 1; }
done
for pair in 'tcp 6' 'udp 17'; do
  read -r protocol number <<< "$pair"
  getent protocols "$protocol" | awk -v number="$number" '$2 == number {found=1} END {exit !found}' || {
    echo "Network protocol lookup failed: $protocol=$number" >&2; exit 1;
  }
done
