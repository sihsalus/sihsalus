#!/bin/sh
set -eu
LIMIT_KB=20971520
USED_KB=$(du -sk /mnt 2>/dev/null | awk "{print \$1}")
case "$USED_KB" in
  *[!0-9]*) USED_KB=0 ;;
esac
FREE_KB=$((LIMIT_KB - USED_KB))
[ "$FREE_KB" -lt 0 ] && FREE_KB=0
printf "%s %s\n" "$FREE_KB" "$LIMIT_KB"
