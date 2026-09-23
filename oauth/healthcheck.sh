#!/usr/bin/env bash
set -euo pipefail

# Keycloak's minimal image includes Bash but no curl. A listening socket is
# insufficient: /health/ready remains non-200 while initialization is pending.
# The optional loopback port is used by the synthetic protocol regression test;
# Compose always uses Keycloak's fixed management port, 9000.
port="${1:-9000}"
if ! [[ "$port" =~ ^[0-9]{1,5}$ ]]; then exit 1; fi
if (( 10#$port < 1 || 10#$port > 65535 )); then exit 1; fi
exec 3<>/dev/tcp/127.0.0.1/"$port"
printf 'HEAD /health/ready HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3
IFS= read -r -t 5 status <&3
[[ "$status" =~ ^HTTP/1\.[01]\ 200([[:space:]]|$) ]]
