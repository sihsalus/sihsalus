# SIHSALUS clinical audit OMOD

This module owns `POST /ws/rest/v1/sihsalus/audit` and the privileged review `GET` on the same path.

- A request is an atomic JSON array of 1 to 50 events and at most 64 KiB.
- `id` is an idempotency UUID. Actor and timestamp are always derived by the server; client `userUuid`, `sessionId`, and `timestamp` are compatibility-only envelope fields and are never persisted.
- Event types, resource types, top-level fields, and scalar metadata keys are explicit allowlists in `AuditPayloadParser`.
- Client `message` and `componentStack` metadata remain accepted for frontend compatibility but are discarded before persistence and review because free text can contain PHI or secrets.
- `Record Clinical Audit Events` permits ingestion. `View Clinical Audit Events` independently permits review.
- Stored rows are immutable through the Hibernate mapping and the service exposes append/read operations only.
- Only this endpoint's 4xx/5xx bodies are replaced with generic JSON while technical exceptions remain in server logs. Repository-wide REST hardening is separate work because changing every OpenMRS error contract has incompatible response and streaming risk.
- There is no server-side rate limiter yet. Authenticated abuse is bounded per request, not over time; an approved gateway or distributed backend limit is required before production promotion.

The `sihsalusaudit.retentionDays` setting is intentionally empty and no automatic deletion runs. A clinical/legal owner must approve a retention duration and deletion/archive procedure before that lifecycle can be enabled.
