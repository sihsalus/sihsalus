#!/usr/bin/env bash
# Shared .env access for the scalar image references and node IDs managed by
# deployment scripts. Never source an environment file as shell code.

read_env_value() {
  local key="$1"
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 2
  awk -v key="$key" '
    $0 ~ ("^[[:space:]]*(export[[:space:]]+)?" key "[[:space:]]*=") {
      value = $0
      sub(/^[^=]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]+$/, "", value)
      quote = substr(value, 1, 1)
      if (quote == "\"" || quote == sprintf("%c", 39)) {
        value = substr(value, 2)
        end = index(value, quote)
        if (end) value = substr(value, 1, end - 1)
      } else {
        sub(/[[:space:]]+#.*$/, "", value)
        sub(/[[:space:]]+$/, "", value)
      }
    }
    END { print value }
  ' .env
}

write_env_value() {
  local key="$1" value="$2" temporary_file
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 2
  # Managed values are unquoted scalars, not secrets or dotenv expressions.
  [[ "$value" =~ ^[A-Za-z0-9_./,:@=+-]*$ ]] || return 2
  temporary_file="$(mktemp ./.env.deploy.XXXXXX)" || return 1
  if ! cp -p .env "$temporary_file" || ! awk -v key="$key" -v value="$value" '
    $0 ~ ("^[[:space:]]*(export[[:space:]]+)?" key "[[:space:]]*=") {
      if (!found) print key "=" value
      found = 1
      next
    }
    { print }
    END { if (!found) print key "=" value }
  ' .env >"$temporary_file" || ! mv -f "$temporary_file" .env; then
    rm -f "$temporary_file"
    return 1
  fi
}
