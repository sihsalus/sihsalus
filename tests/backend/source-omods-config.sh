#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_ROOT="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

mkdir -p "$FIXTURE_ROOT/backend/bin" "$FIXTURE_ROOT/bin" "$FIXTURE_ROOT/source"
cp "$ROOT_DIR/backend/bin/build-source-omods.sh" "$FIXTURE_ROOT/backend/bin/"
printf '<project/>\n' > "$FIXTURE_ROOT/source/pom.xml"
tar -czf "$FIXTURE_ROOT/source.tar.gz" -C "$FIXTURE_ROOT" source
if command -v sha256sum >/dev/null; then
  checksum="$(sha256sum "$FIXTURE_ROOT/source.tar.gz" | awk '{print $1}')"
else
  checksum="$(shasum -a 256 "$FIXTURE_ROOT/source.tar.gz" | awk '{print $1}')"
fi
for module in alpha beta; do
  printf '%s synthetic/module %040d %s 1.0.0-SNAPSHOT 1.0.0-test\n' "$module" 0 "$checksum"
done > "$FIXTURE_ROOT/backend/omod-sources.lock"

# Both external commands are replaced. Archives and Maven reports are local,
# synthetic fixtures; no network, Java process or real Maven cache is used.
cat > "$FIXTURE_ROOT/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
output=''
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == --output ]]; then output="$2"; shift; fi
  shift
done
module="${output##*/}"
module="${module%.tar.gz}"
[[ "$module" == alpha || "$module" == beta ]] || exit 90
[[ "$module" != "${SYNTHETIC_FAIL_DOWNLOAD:-}" ]] || exit 22
cp "$SYNTHETIC_MODULE_ARCHIVE" "$output"
CURL

cat > "$FIXTURE_ROOT/bin/mvn" <<'MAVEN'
#!/usr/bin/env bash
set -euo pipefail
pom=''
last=''
while [[ "$#" -gt 0 ]]; do
  last="$1"
  if [[ "$1" == -f ]]; then pom="$2"; shift; fi
  shift
done
[[ -f "$pom" ]] || exit 91
[[ "$last" == install ]] || exit 0
source_dir="${pom%/*}"
module="${source_dir##*/}"
mkdir -p "$source_dir/api/target/surefire-reports"
printf '<testsuite name="%s" tests="1"/>\n' "$module" \
  > "$source_dir/api/target/surefire-reports/TEST-fixture.xml"
[[ "$module" != "${SYNTHETIC_FAIL_MAVEN:-}" ]] || exit 17
MAVEN
chmod 0700 "$FIXTURE_ROOT/bin/curl" "$FIXTURE_ROOT/bin/mvn"

failures=0
for scenario in success selected download-failure maven-failure; do
  case_root="$FIXTURE_ROOT/$scenario"
  mkdir -p "$case_root/tmp" "$case_root/reports" "$case_root/expected"
  selected=all
  expected_status=0
  fail_download=''
  fail_maven=''
  expected_modules='alpha beta'
  case "$scenario" in
    selected) selected=alpha; expected_modules=alpha ;;
    download-failure) fail_download=beta; expected_status=22; expected_modules=alpha ;;
    maven-failure) fail_maven=beta; expected_status=17 ;;
  esac
  for module in $expected_modules; do
    mkdir -p "$case_root/expected/$module"
    printf '<testsuite name="%s" tests="1"/>\n' "$module" \
      > "$case_root/expected/$module/TEST-fixture.xml"
  done
  status=0
  PATH="$FIXTURE_ROOT/bin:$PATH" TMPDIR="$case_root/tmp" \
    SYNTHETIC_MODULE_ARCHIVE="$FIXTURE_ROOT/source.tar.gz" \
    SYNTHETIC_FAIL_DOWNLOAD="$fail_download" SYNTHETIC_FAIL_MAVEN="$fail_maven" \
    OMOD_TEST_REPORTS="$case_root/reports" \
    bash "$FIXTURE_ROOT/backend/bin/build-source-omods.sh" test "$selected" \
    > "$case_root/output.log" 2>&1 || status=$?

  # Exact trees and contents reject root-level duplicates, cross-module copies,
  # missing failure reports and abandoned extracted sources.
  if [[ "$status" -ne "$expected_status" ]] \
    || ! diff -r "$case_root/expected" "$case_root/reports" > "$case_root/report-diff.log" \
    || [[ -n "$(find "$case_root/tmp" -mindepth 1 -print -quit)" ]]; then
    echo "[FAIL] source OMOD report ownership/cleanup: $scenario"
    failures=$((failures + 1))
  else
    echo "[OK] source OMOD report ownership/cleanup: $scenario"
  fi
done
[[ "$failures" -eq 0 ]]
