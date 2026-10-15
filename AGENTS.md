# Instructions for SIHSalus operations

Read [README.md](README.md) and the affected operational guide before editing.
Reuse the existing deployment, backup, and verification tools. Preserve local
work, credentials, applied migrations, and retained recovery images.

## Human control

Agents may investigate, prepare isolated changes, and run local checks. Present
the final diff, alternatives, failure modes, and executed/pending verification
so a maintainer can understand and challenge the result.

Merges, release publication, deployments, shared infrastructure changes,
privilege grants, credential resets, and destructive operations require explicit
human approval of the concrete result. Identify the exact PR head, manifest
checksum/image digest and environment, or account and role change. A broad
“yolo”, a plan approval, green CI, or a previous deployment is insufficient.
Material changes invalidate approval for the changed scope.

Agents must not approve their own reviews/deployments through the maintainer's
credentials, enable auto-merge, bypass protections, or fill the human decision
in the PR template. Leave the prepared result for review. Merge authorization
and deployment authorization are separate.

Use the [human review procedure](docs/operations/human-review.md) together with
the [deployment checklist](docs/operations/deploy-checklist.md). Clinical and
permission decisions require the responsible domain reviewer. Report technical
health, authentication, and clinical acceptance as distinct results.
