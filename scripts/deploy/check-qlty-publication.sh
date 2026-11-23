#!/usr/bin/env bash
# A publication can finish after a newer one, or be rerun long after its merge.
set -euo pipefail

repo=sihsalus/sihsalus
[[ "$GITHUB_REPOSITORY" == "$repo" && "$GITHUB_EVENT_NAME" == push && "$GITHUB_REF" == refs/heads/main ]]
[[ "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]]

pr="$(gh api "repos/$repo/commits/$GITHUB_SHA/pulls" | jq -er --arg sha "$GITHUB_SHA" '
  first(.[] | select(.merged_at and .base.ref == "main" and .base.repo.full_name == "sihsalus/sihsalus" and .merge_commit_sha == $sha) | .html_url)')"
ci_id="$(gh api "repos/$repo/actions/workflows/ci.yml/runs?branch=main&event=push&head_sha=$GITHUB_SHA&per_page=1" |
  jq -er --arg sha "$GITHUB_SHA" '.workflow_runs[0] | select(.head_sha == $sha) | .id')"
gh run watch "$ci_id" --repo "$repo" --interval 30 --exit-status

# Inspect the most recent completed drill, including failed ones.
drill="$(gh api "repos/$repo/actions/workflows/physical-backup-drill.yml/runs?branch=main&status=completed&per_page=1" |
  jq -er '.workflow_runs[0] | select(.conclusion == "success" and (.head_sha | test("^[0-9a-f]{40}$")) and
    (.html_url | startswith("https://github.com/sihsalus/sihsalus/actions/runs/")) and
    (.updated_at | fromdateiso8601 > 0)) | [.html_url, .head_sha, .updated_at] | @tsv')"
{
  echo "Merged PR: $pr"
  echo "CI: https://github.com/$repo/actions/runs/$ci_id"
  echo "Backup and restore drills (URL, commit, date): $drill"
} >> "$GITHUB_STEP_SUMMARY"

latest="$(gh api "repos/$repo/actions/workflows/build-backend.yml/runs?branch=main&event=push&per_page=1" |
  jq -er '.workflow_runs[0].head_sha')"
[[ "$latest" =~ ^[0-9a-f]{40}$ ]]
if [[ "$latest" != "$GITHUB_SHA" ]]; then
  echo "A newer backend publication ($latest) supersedes $GITHUB_SHA. Skipping QLTY." >> "$GITHUB_STEP_SUMMARY"
  echo "deploy=false" >> "$GITHUB_OUTPUT"
else
  echo "deploy=true" >> "$GITHUB_OUTPUT"
fi
