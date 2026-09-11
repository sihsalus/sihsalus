#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
usage() {
  echo "Usage: $0 IMAGE | --files WAR MODULES_DIRECTORY | --self-test WAR" >&2
  exit 2
}
[[ "$#" -gt 0 ]] || usage
MODE=image
case "$1" in
  --self-test) [[ "$#" -eq 2 ]] || usage; MODE=self-test; CORE_WAR="$2" ;;
  --files) [[ "$#" -eq 3 ]] || usage; MODE=files; CORE_WAR="$2"; MODULES_DIR="$3" ;;
  -*) usage ;;
  *) [[ "$#" -eq 1 && -n "$1" ]] || usage; IMAGE="$1" ;;
esac

for command in java javac jar; do
  command -v "$command" >/dev/null || { echo "[FAIL] JDK required: $command is missing" >&2; exit 1; }
done
TEMP_DIR="$(mktemp -d)"
CONTAINER_ID=""
cleanup() {
  local status=$?
  if [[ -n "$CONTAINER_ID" ]] && ! docker rm --volumes "$CONTAINER_ID" >/dev/null; then
    echo "[FAIL] Could not remove test container $CONTAINER_ID; cleanup state retained in $TEMP_DIR" >&2
    [[ "$status" -ne 0 ]] || status=1
    return "$status"
  fi
  rm -rf -- "$TEMP_DIR"
  return "$status"
}
trap cleanup EXIT

if [[ "$MODE" == image ]]; then
  # Inspect only distribution files. Never start OpenMRS or attach runtime data.
  CONTAINER_ID="$(docker create --network none --entrypoint /bin/true "$IMAGE")"
  [[ "$CONTAINER_ID" =~ ^[0-9a-f]{64}$ ]] || {
    echo "[FAIL] Docker did not return a valid test container ID" >&2
    CONTAINER_ID=""
    exit 1
  }
  printf '%s\n' "$CONTAINER_ID" > "$TEMP_DIR/container-id"
  MODULES_DIR="$TEMP_DIR/modules"
  CORE_WAR="$TEMP_DIR/openmrs.war"
  mkdir "$MODULES_DIR"
  docker cp "$CONTAINER_ID:/openmrs/distribution/openmrs_modules/." "$MODULES_DIR/"
  docker cp "$CONTAINER_ID:/openmrs/distribution/openmrs_core/openmrs.war" "$CORE_WAR"
fi

[[ -f "$CORE_WAR" ]] || { echo '[FAIL] Core WAR is missing' >&2; exit 1; }
CORE_WAR="$(cd "$(dirname "$CORE_WAR")" && pwd)/$(basename "$CORE_WAR")"
jar tf "$CORE_WAR" > "$TEMP_DIR/war-entries"
ENTRIES=()
for artifact in openmrs-api slf4j-api commons-lang3; do
  matches=()
  while IFS= read -r entry; do
    if [[ "$entry" =~ ^WEB-INF/lib/${artifact}-[^/]+\.jar$ ]]; then
      matches+=("$entry")
    fi
  done < "$TEMP_DIR/war-entries"
  [[ "${#matches[@]}" -eq 1 ]] || {
    echo "[FAIL] Expected exactly one $artifact JAR in the packaged Core WAR" >&2
    exit 1
  }
  ENTRIES+=("${matches[0]}")
done
mkdir "$TEMP_DIR/core" "$TEMP_DIR/classes"
(
  cd "$TEMP_DIR/core"
  jar xf "$CORE_WAR" "${ENTRIES[@]}"
)
CLASSPATH="$TEMP_DIR/core/WEB-INF/lib/*"
echo "[INFO] Required-version comparator: ${ENTRIES[0]} from the supplied Core WAR"
# Compile a test harness only, never module/application source. Its comparator
# is the exact ModuleUtil bytecode from this image's WAR, not a SemVer substitute.
javac --release 11 -cp "$CLASSPATH" -d "$TEMP_DIR/classes" \
  "$ROOT_DIR/tests/backend/ModuleDependencyVerifier.java"
java -cp "$TEMP_DIR/classes:$CLASSPATH" ModuleDependencyVerifier --self-test "$TEMP_DIR/fixtures"
if [[ "$MODE" != self-test ]]; then
  java -cp "$TEMP_DIR/classes:$CLASSPATH" ModuleDependencyVerifier "$MODULES_DIR"
fi
