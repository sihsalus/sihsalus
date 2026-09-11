#!/bin/sh
set -eu

# The generator uses 24 random bytes encoded as lowercase hex. Restrict this
# new credential's format so a malformed value can neither alter Redis config
# nor appear in a Redis parser error. Never put it on the process command line.
case "${IMAGING_REDIS_PASSWORD:-}" in
  ""|*[!0-9a-f]*)
    echo "IMAGING_REDIS_PASSWORD must contain 48 lowercase hexadecimal characters" >&2
    exit 1
    ;;
esac
if [ "${#IMAGING_REDIS_PASSWORD}" -ne 48 ]; then
  echo "IMAGING_REDIS_PASSWORD must contain 48 lowercase hexadecimal characters" >&2
  exit 1
fi

umask 077
config_file="$(mktemp /data/imaging-redis.conf.XXXXXX)"
cat > "$config_file" <<'EOF'
bind 0.0.0.0
port 6379
protected-mode yes
daemonize no
loglevel warning
logfile ""
save ""
appendonly no
dir /data
maxmemory 128mb
maxmemory-policy noeviction
timeout 0
tcp-keepalive 60
EOF
printf 'requirepass "%s"\n' "$IMAGING_REDIS_PASSWORD" >> "$config_file"
unset IMAGING_REDIS_PASSWORD
exec redis-server "$config_file"
