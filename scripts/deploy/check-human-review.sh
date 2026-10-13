#!/usr/bin/env bash
# Verify native GitHub environment protections before scheduling deployment jobs.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo 'Usage: check-human-review.sh <environment> [...]' >&2
  exit 2
fi
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

for environment in "$@"; do
  [[ "$environment" =~ ^[A-Za-z0-9_-]+$ ]] || exit 2
  policy="$(gh api "repos/$GITHUB_REPOSITORY/environments/$environment")"
  if ! jq -e '
    .can_admins_bypass == false and
    any(.protection_rules[]?;
      .type == "required_reviewers" and
      (.reviewers | type == "array" and length > 0) and
      all(.reviewers[];
        (.type == "User" and .reviewer.type == "User") or .type == "Team"))
  ' <<< "$policy" >/dev/null; then
    echo "::error::Configure required human reviewers and disable administrator bypass for $environment. See docs/operations/human-review.md." >&2
    exit 1
  fi
  echo "Native human-review protection verified: $environment"
done
