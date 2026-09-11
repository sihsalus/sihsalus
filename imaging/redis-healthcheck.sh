#!/bin/sh
set -eu

# redis-cli's dedicated auth environment avoids disclosing the password in
# argv or the healthcheck output. Docker supplies the execution timeout.
response="$(REDISCLI_AUTH="${IMAGING_REDIS_PASSWORD:?}" redis-cli --no-auth-warning ping 2>/dev/null)" || exit 1
[ "$response" = "PONG" ]
