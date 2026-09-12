#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-package}"
SELECTED_MODULE="${2:-all}"
[[ "$MODE" == package || "$MODE" == test || "$MODE" == test-core28 ]] \
  || { echo 'Expected package, test or test-core28' >&2; exit 2; }
[[ "$MODE" != test-core28 || "$SELECTED_MODULE" == initializer ]] \
  || { echo 'test-core28 requires initializer and its previously installed reactor artifacts' >&2; exit 2; }
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sihsalus-omods.XXXXXX")"
save_reports() {
  if [[ -n "${OMOD_TEST_REPORTS:-}" && -n "${source_dir:-}" && -d "$source_dir" ]]; then
    mkdir -p "$OMOD_TEST_REPORTS/$module"
    while IFS= read -r report; do
      cp "$report" "$OMOD_TEST_REPORTS/$module/"
    done < <(find "$source_dir" -path '*/surefire-reports/TEST-*.xml' -type f)
  fi
}
cleanup() {
  save_reports
  rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT
MAVEN=(mvn --batch-mode --no-transfer-progress -Dstyle.color=never)
if [[ -n "${OMOD_MAVEN_REPOSITORY:-}" ]]; then
  MAVEN+=("-Dmaven.repo.local=$OMOD_MAVEN_REPOSITORY")
fi
matched=false
while read -r module repository revision checksum upstream_version version extra; do
  [[ -z "$module" || "$module" == \#* ]] && continue
  [[ "$SELECTED_MODULE" == all || "$SELECTED_MODULE" == "$module" ]] || continue
  [[ "$revision" =~ ^[0-9a-f]{40}$ && "$checksum" =~ ^[0-9a-f]{64}$ && -z "$extra" ]] \
    || { echo "Invalid lock entry for $module" >&2; exit 1; }
  matched=true
  echo "[source-omods] $module $version from $repository@$revision ($MODE)"
  archive="$BUILD_ROOT/$module.tar.gz"
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 20 \
    "https://codeload.github.com/$repository/tar.gz/$revision" --output "$archive"
  if command -v sha256sum >/dev/null; then
    actual_checksum="$(sha256sum "$archive" | awk '{print $1}')"
  else
    actual_checksum="$(shasum -a 256 "$archive" | awk '{print $1}')"
  fi
  [[ "$actual_checksum" == "$checksum" ]] || { echo "Archive checksum mismatch: $module" >&2; exit 1; }
  source_dir="$BUILD_ROOT/$module"
  mkdir "$source_dir"
  tar -xzf "$archive" -C "$source_dir" --strip-components=1
  "${MAVEN[@]}" -f "$source_dir/pom.xml" \
    org.codehaus.mojo:versions-maven-plugin:2.19.1:set \
    "-DnewVersion=$version" -DgenerateBackupPoms=false -DprocessAllModules=true
  args=(-Dformatter.skip=true -Dspotless.skip=true -Dmaven.javadoc.skip=true)
  if [[ "$MODE" == package ]]; then
    # Initializer consumes sibling test-jars even when not running tests.
    args+=(-DskipTests)
  fi
  if [[ "$MODE" == test-core28 ]]; then
    # The complete Initializer reactor was installed by its Java 11 test job.
    args+=(-pl api-2.8)
  fi
  if [[ "$MODE" == test-core28 || ( "$MODE" == test && "$module" == patientdocuments ) ]]; then
    # Legacy CGLIB/PowerMock tests need reflective class loading on Java 21.
    # The environment reaches forked Surefire JVMs without replacing upstream argLine.
    JDK_JAVA_OPTIONS="${JDK_JAVA_OPTIONS:-} --add-opens=java.base/java.lang=ALL-UNNAMED" \
      "${MAVEN[@]}" -f "$source_dir/pom.xml" "${args[@]}" install
  else
    "${MAVEN[@]}" -f "$source_dir/pom.xml" "${args[@]}" install
  fi
  save_reports
  # Reports are already saved; a later download failure must not reuse this source.
  source_dir=""
  echo "[source-omods] verified $module $version"
done < "$ROOT/omod-sources.lock"
[[ "$matched" == true ]] || { echo "Unknown source module: $SELECTED_MODULE" >&2; exit 2; }
