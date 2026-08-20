# Production frontend promotion

This runbook configures and operates the manual, fail-closed frontend promotion
path in `.github/workflows/promote-frontend-production.yml`. It changes only the
`frontend` service. It does not recreate the gateway, OpenMRS, databases, FUA,
or any other service.

The workflow is intentionally unusable until the `production` GitHub
environment and its protected values have been configured. Do not replace
missing values with DEV, QLTY, guessed, or copied host identities.

## One-time repository configuration

Create a GitHub environment named `production` and configure all of the
following controls:

- require at least one authorized human production reviewer;
- prevent the workflow initiator from self-approving when the repository plan
  supports that control;
- restrict deployment branches to `main`;
- do not allow an administrator bypass during a normal release;
- keep the environment secret `SSH_PRIVATE_KEY_PROD` scoped to a
  least-privilege account that can update this repository checkout and the
  frontend container only.

Configure these environment variables without putting their values in Git:

| Variable                         | Required contract                                     |
| -------------------------------- | ----------------------------------------------------- |
| `SSH_KNOWN_HOSTS_PROD`           | Pinned SSH host key for the production target         |
| `PRODUCTION_SSH_TARGET`          | Exact `user@host` deployment target                   |
| `PRODUCTION_REMOTE_REPOSITORY`   | Absolute path to the clean SIH Salus distro checkout  |
| `PRODUCTION_BASE_URL`            | Public HTTPS origin without a path                    |
| `PRODUCTION_EXPECTED_REMOTE_MAC` | Lowercase MAC of the intended production interface    |
| `PRODUCTION_EXPECTED_NODE_ID`    | Stable lowercase UUID exposed as `X-SIHSALUS-Node-ID` |

Before enabling the environment, verify the SSH host key and physical MAC from
an independent infrastructure inventory. Generate a new production node UUID;
never reuse the DEV or QLTY identity. Record the values in the private
operations inventory, not in an issue, PR, workflow log, or screenshot.

## Release gate

Do not approve the protected environment until all of these statements are
true for the exact requested frontend SHA and digest:

1. the frontend PR was reviewed and merged, and its CI, CodeQL, image build,
   and release scan passed;
2. the same immutable SHA is currently healthy in QLTY;
3. the applicable synthetic-data clinical matrix passed in QLTY and identifies
   the same SHA/digest;
4. backend, content, OMOD, metadata, privileges, and configuration dependencies
   are compatible;
5. a recent backup and the current production frontend SHA/digest are recorded;
6. the on-call operator, rollback owner, and post-deployment smoke owner are
   available for the change window.

CI or a healthy container is not clinical approval. A `BLOCKED`, stale, or
partially executed QLTY result is not a pass.

## Promote

Open **Actions → Promote Frontend to Production → Run workflow** and select the
current `main` branch. Supply:

- `operation`: `promote`;
- `frontend_sha` and `frontend_digest`: the QLTY-accepted immutable candidate;
- `current_production_sha` and `current_production_digest`: the exact release
  currently deployed and retained for rollback;
- `confirmation`: `PROMOTE <frontend_sha> TO PRODUCTION`, replacing the
  placeholder with the full 40-character SHA.

The workflow rejects any non-`main` invocation, malformed identifier,
mismatched SHA/digest, candidate that is not the current scanned `latest`
release, candidate not live in QLTY, or incorrect confirmation. The protected
production job then:

1. validates every environment value and the pinned SSH key;
2. confirms the declared current SHA through repeated public requests;
3. validates the remote MAC before every SSH operation;
4. deploys the candidate by digest and recreates only `frontend`;
5. verifies health, source revision, runtime image, and node identity locally;
6. samples the public endpoint repeatedly and requires one SHA, one remote
   address, and the expected node identity;
7. records the operation, SHA, digest, and successful external verification in
   the workflow summary.

If local deployment fails, `deploy-frontend.sh` restores the prior container.
If deployment or public verification fails, the workflow additionally
re-deploys the supplied current SHA/digest, verifies it publicly, and fails the
run. A failed rollback remains an incident even if the endpoint later appears
healthy.

## Roll back after a completed promotion

Run the same workflow with:

- `operation`: `rollback`;
- `frontend_sha` and `frontend_digest`: the previously accepted immutable
  release to restore;
- `current_production_sha` and `current_production_digest`: the release being
  replaced;
- `confirmation`: `ROLLBACK <frontend_sha> IN PRODUCTION`.

Rollback does not require the target to be the `latest` alias or currently live
in QLTY, but it still validates the immutable image revision and digest,
requires production approval, verifies the current public release before the
change, and executes the same post-deployment checks.

## Close the change window

Record the workflow run URL, actor and approving reviewer, start/end time,
source SHA/digest, previous SHA/digest, external verification result, smoke
result, and any incident reference. Run the role-appropriate production smoke
without real-patient mutation or screenshots containing PHI. Keep the previous
immutable artifact recorded until the change window is formally closed.
