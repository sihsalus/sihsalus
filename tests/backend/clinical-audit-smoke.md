# Clinical audit endpoint acceptance in DEV

Run only against the coordinated DEV instance after its exact candidate image
passes the image gates and OpenMRS finishes startup. This is a black-box REST
test of the assembled distribution, not a patient workflow or a retention test.
The module's Java tests remain in its owning repository.

Provision three distinct, dedicated users through OpenMRS administration:

| Configuration actor | Required audit privilege | Audit privilege it must not have |
| --- | --- | --- |
| `record` | `Record Clinical Audit Events` | `View Clinical Audit Events` |
| `review` | `View Clinical Audit Events` | `Record Clinical Audit Events` |
| `denied` | Neither | Both |

Use usernames beginning with `audit_dev_`, unique to the acceptance run. None
may inherit a superuser role. Keep their generated credentials outside Git in
a JSON file accessible only to its owner (`0600`). Example structure:

```json
{
  "environment": "dev",
  "base_url": "https://dev.example.org",
  "expected_node_id": "EXPECTED-DEV-NODE-UUID",
  "actors": {
    "record": { "username": "audit_dev_record_RUN", "password": "PRIVATE" },
    "review": { "username": "audit_dev_review_RUN", "password": "PRIVATE" },
    "denied": { "username": "audit_dev_denied_RUN", "password": "PRIVATE" }
  }
}
```

For a certificate obtained through an authenticated, identity-checked channel,
`ca_file` can name that trusted PEM. If running on the verified DEV host,
`connect_address: "127.0.0.1"` connects locally while retaining hostname and
certificate verification. It does not disable TLS checks.

```sh
python3 tests/backend/clinical-audit-smoke.py \
  --config /private/location/audit-dev-credentials.json \
  --report /private/location/audit-dev-result.json
```

The runner checks the frontend node identity before authenticating. It verifies
the two endpoint paths, positive/negative RBAC, server-derived actor/receipt
time, metadata minimisation, sequential/concurrent idempotency, batch rollback,
invalid payloads and HTTP methods, response redaction and cache prevention.
It appends only synthetic search/error events, without creating or changing
patients. It intentionally retains accepted events.

The report lists checks, synthetic event IDs and actor UUIDs, without passwords
or complete response bodies. Use a new report path for every execution. After
acceptance, retire test accounts through OpenMRS; do not purge audit actors or
events. Keep the private provisioning journal until every created account has
been accounted for.

Separately verify MariaDB migration/triggers, startup after a second restart,
preservation of the accepted events, and browser offline replay. A green REST
run alone does not establish these properties or full clinical event coverage.
