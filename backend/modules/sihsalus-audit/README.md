# SIHSALUS clinical audit OMOD

This module owns `POST /ws/rest/v1/sihsalus/audit` and the privileged review `GET` on the same path.

- A request is an atomic JSON array of 1 to 50 events and at most 64 KiB.
- `id` is an idempotency UUID. Writes for the same actor are serialized with a database row lock, so simultaneous retries return the stored event instead of surfacing a uniqueness failure.
- Actor and receive time are always derived by the server. Client `userUuid` and `sessionId` are compatibility-only and never persisted. Client `timestamp` is retained separately as non-authoritative `occurredAt`; `timestamp`/`receivedAt` in review remain the authoritative server receive time.
- Event types, resource types, top-level fields, and scalar metadata keys are explicit allowlists in `AuditPayloadParser`. Clinical event families require their patient/encounter target and receive a normalized resource type. `PERMISSION_CHANGE` additionally requires the applicable OpenMRS role/user-management privilege.
- Free-text-compatible metadata remains accepted but is discarded. Persistence is limited to an enumerated frontend `appName`, enumerated `outcome`, boolean `offline`, and UUID `locationUuid`; unknown machine values are also discarded so they cannot become a durable PHI/secret channel.
- `Record Clinical Audit Events` permits ingestion. `View Clinical Audit Events` independently permits review.
- Stored rows are immutable through the Hibernate mapping and append/read service. MariaDB/MySQL update and delete triggers add database-level enforcement; an approved retention migration must explicitly replace those triggers before archival or deletion.
- Both `/audit` and `/audit/` are covered by the endpoint-only response sanitizer. Responses stay buffered within a 512 KiB endpoint bound so a later error cannot expose a partial raw body. Technical exceptions remain in server logs.
- A bounded per-node limiter permits 20 requests per second per authenticated actor and returns `429` with `Retry-After`. An approved gateway or distributed limit remains required before multi-node production promotion.
- Liquibase uses one recoverable implicit-commit DDL operation per change set, rechecks append-only triggers on startup, and halts on a final schema validation mismatch.

The `sihsalusaudit.retentionDays` setting is intentionally empty and no automatic deletion runs. A clinical/legal owner must approve a retention duration and deletion/archive procedure before that lifecycle can be enabled.
