# SIHSALUS clinical audit OMOD

This module owns `POST /ws/rest/v1/sihsalus/audit` and the privileged review `GET` on the same path.

- A request is an atomic JSON array of 1 to 50 events and at most 64 KiB.
- `id` is an idempotency UUID. Writes for the same actor are serialized with a database row lock, so simultaneous retries return the stored event instead of surfacing a uniqueness failure.
- Actor and receive time are always derived by the server. Client `userUuid` and `sessionId` are compatibility-only, ignored regardless of shape, and never persisted. A valid client `timestamp` is retained separately as non-authoritative `occurredAt`; malformed or database-incompatible client times are discarded rather than blocking an offline batch. `timestamp`/`receivedAt` in review remain the authoritative server receive time.
- Event types, resource types, top-level fields, and metadata field names are explicit allowlists in `AuditPayloadParser`. Clinical event families require their patient/encounter target and receive a normalized resource type.
- Client `PERMISSION_CHANGE` events are non-authoritative telemetry. Delayed ingestion intentionally does not recheck a current `Manage Roles` or `Edit Users` privilege because that would lose offline history without proving authorization at mutation time. Authoritative permission auditing still requires a server-side hook in the permission mutation transaction.
- Values for allowed metadata keys remain accepted within the 64 KiB request bound, but persistence is limited to an enumerated frontend `appName`, enumerated `outcome`, boolean `offline`, and UUID `locationUuid`. Free text, malformed values, and unknown machine values are discarded so they cannot poison an offline batch or become a durable PHI/secret channel. Review applies the same canonicalization to legacy rows and omits malformed metadata without changing the stored evidence.
- `Record Clinical Audit Events` permits ingestion. `View Clinical Audit Events` independently permits review.
- Stored rows are immutable through the Hibernate mapping and append/read service. MariaDB/MySQL update and delete triggers add database-level enforcement; missing triggers are recreated and an unexpected trigger body halts startup instead of silently accepting weaker protection. The migration identity needs permission to inspect and create triggers. An approved retention migration must explicitly replace those triggers before archival or deletion.
- Both `/audit` and `/audit/` are covered by the endpoint-only response sanitizer. Every success and error response carries `Cache-Control: no-store`. Responses stay buffered within a 512 KiB endpoint bound so a later error cannot expose a partial raw body. Technical exceptions remain in server logs.
- A bounded per-node limiter permits 20 requests per second per authenticated actor and returns `429` with `Retry-After`. An approved gateway or distributed limit remains required before multi-node production promotion.
- Liquibase uses one recoverable implicit-commit DDL operation per change set, validates MariaDB/MySQL's `PRIMARY` key name and column explicitly, rechecks exact append-only trigger actions on startup, and halts on a final schema validation mismatch.

The `sihsalusaudit.retentionDays` setting is intentionally empty and no automatic deletion runs. A clinical/legal owner must approve a retention duration and deletion/archive procedure before that lifecycle can be enabled.

The frontend still needs contract-side validation plus dead-letter/quarantine handling for any future rejected event shape. Until that work is delivered, a newly introduced incompatible field can still stall an atomic offline batch even though invalid client timestamps and long discarded error text no longer do.
