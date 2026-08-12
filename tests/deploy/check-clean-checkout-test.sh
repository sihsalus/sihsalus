#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT/scripts/deploy/check-clean-checkout.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sihsalus-clean-checkout-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

git -C "$TEST_ROOT" init --quiet
git -C "$TEST_ROOT" config user.name 'SIHSALUS CI'
git -C "$TEST_ROOT" config user.email 'ci@example.test'
mkdir -p "$TEST_ROOT/compose"
printf '%s\n' 'reviewed configuration' >"$TEST_ROOT/compose/fua.yml"
git -C "$TEST_ROOT" add compose/fua.yml
git -C "$TEST_ROOT" commit --quiet -m 'test fixture'

(
  cd "$TEST_ROOT"
  bash "$HELPER" test-deploy
)

printf '%s\n' 'sensitive-local-content-must-not-leak' >"$TEST_ROOT/compose/fua.yml"
if dirty_output="$(cd "$TEST_ROOT" && bash "$HELPER" test-deploy 2>&1)"; then
  echo "[FAIL] clean-checkout helper accepted a tracked modification" >&2
  exit 1
fi
grep -Fq 'compose/fua.yml' <<<"$dirty_output"
grep -Fq 'move these changes to a pull request' <<<"$dirty_output"
if grep -Fq 'sensitive-local-content-must-not-leak' <<<"$dirty_output"; then
  echo "[FAIL] clean-checkout helper printed file contents" >&2
  exit 1
fi

git -C "$TEST_ROOT" restore compose/fua.yml
printf '%s\n' 'ignored by tracked-only policy' >"$TEST_ROOT/local-note.txt"
(
  cd "$TEST_ROOT"
  bash "$HELPER" test-deploy
)

printf '%s\n' 'services: {}' >"$TEST_ROOT/compose.override.yml"
if override_output="$(cd "$TEST_ROOT" && bash "$HELPER" test-deploy 2>&1)"; then
  echo "[FAIL] clean-checkout helper accepted an untracked automatic Compose override" >&2
  exit 1
fi
grep -Fq 'compose.override.yml' <<<"$override_output"
grep -Fq 'refusing to deploy' <<<"$override_output"
if grep -Fq 'services: {}' <<<"$override_output"; then
  echo "[FAIL] clean-checkout helper printed Compose override contents" >&2
  exit 1
fi

echo "[OK] clean checkout diagnostics"
