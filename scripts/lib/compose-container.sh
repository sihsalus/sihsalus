#!/bin/sh
# Resolve the container of a Compose service in the active project.
#
# Containers no longer have fixed names (<project>-<service>-1 is assigned by
# Compose), so operational scripts look them up by service. "docker compose"
# selects the project from the directory it runs in (.env, COMPOSE_FILE and
# COMPOSE_PROFILES; a relative COMPOSE_FILE resolves against that directory),
# so callers either run from the checkout or pass it as the second argument.
# Scripts that cron or systemd may start from another directory pass their
# own checkout, derived from their path.
# POSIX sh: it is shared by bash and /bin/sh scripts.

# compose_container SERVICE [DIRECTORY]
# Print the first container id of a service, or nothing if none exists.
# DIRECTORY is the checkout that selects the project; default: the current one.
compose_container() {
  (
    if [ -n "${2:-}" ]; then
      cd "$2" || exit 1
    fi
    docker compose ps --all --quiet "$1"
  ) | head -n 1
}

# require_compose_container SERVICE [DIRECTORY]
# Print the container id of a service and fail when the project has none.
require_compose_container() {
  container_id="$(compose_container "$1" "${2:-}")" || container_id=""
  if [ -z "$container_id" ]; then
    echo "[compose-container] no container for service '$1' in the Compose project of ${2:-$PWD}" >&2
    return 1
  fi
  printf '%s\n' "$container_id"
}
