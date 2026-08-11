# ADR-011: Event Identity and Best-Effort Idempotency (First Cut)

**Status:** Accepted
**Date:** 2026-08-07

## Context

Best-effort delivery (ADR-005) plus MQTT store-and-forward (ADR-008) means an event can be delivered more than once (buffer re-read after a `guardian-core` restart, uplink resend) and, in the MVP, sometimes zero times (an explicit gap). We want a stable-enough identity to deduplicate the cases that would be visibly wrong, without paying for strict process-once semantics the first cut does not need.

## Decision

- **Event identity** is `(session id, sequence number)` (ADR-004): it labels events for ordering and cheap dedup. It is not a strong global key in the MVP, and nothing safety-relevant depends on strict idempotency.
- **Idempotency is best-effort, applied where it is cheap and where duplicates would be visibly wrong** — not a blanket guarantee:
  - **Uplink** carries the finding/alert's stable key as an idempotency token so the backend can dedupe resends. This is the one place we rely on it.
  - **Alert transitions** are applied against current state, so a re-applied transition is naturally a no-op.
  - **Telemetry** may be upserted on identity where convenient; occasional duplicate or re-counted telemetry in the first cut is acceptable (the data is lossy anyway) and is tightened later.
- Exactly-once effect application is **not** guaranteed. Strengthening this (durable de-dup, strictly once-only findings) is a later ADR alongside the durable ingestion tier.

## Consequences

- Simple first cut: dedup where it matters (uplink, alert state), tolerate duplicates elsewhere.
- Identity and uplink tokens already exist, so tightening idempotency later is additive, not a rewrite.

## Alternatives considered

- **Strict at-least-once with full idempotency everywhere** — deferred: unnecessary rigor for a lossy first cut; revisited with the durable ingestion tier.
