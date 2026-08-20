# SIHSALUS clinical audit OMOD

This module owns `POST /ws/rest/v1/sihsalus/audit` and the privileged review `GET` on the same path.

- A request is an atomic JSON array of 1 to 50 events and at most 64 KiB.
- `id` is an idempotency UUID. Actor and timestamp are always derived by the server; client `userUuid`, `sessionId`, and `timestamp` are compatibility-only envelope fields and are never persisted.
- Event types, resource types, top-level fields, and scalar metadata keys are explicit allowlists in `AuditPayloadParser`.
- `Record Clinical Audit Events` permits ingestion. `View Clinical Audit Events` independently permits review.
- Stored rows are immutable through the Hibernate mapping and the service exposes append/read operations only.
- REST 4xx/5xx bodies are globally replaced with generic JSON while technical exceptions remain in server logs.

The `sihsalusaudit.retentionDays` setting is intentionally empty and no automatic deletion runs. A clinical/legal owner must approve a retention duration and deletion/archive procedure before that lifecycle can be enabled.
