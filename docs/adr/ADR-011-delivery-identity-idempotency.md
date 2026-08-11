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

### Known limitation (first cut — deliberately deferred)

A `guardian-core` restart can re-deliver a Tier-2 safety event whose SQLite effect committed **before** the last-seen marker advanced, so across the restart window a **finding may be duplicated or an incident reopened/reclosed**. This is an accepted first-cut limitation, not an oversight:

- it is bounded to the rare restart window and visible (the duplicate is recorded, never silent);
- it errs toward *more* findings, never a missed detection — it cannot hide a real condition;
- telemetry duplicates remain explicitly acceptable.

The fix — a deterministic effect id on the low-volume Tier-2 transitions (findings, incident open/close, alert transitions, acks, device-health, safety-relevant outbound) plus atomic duplicate suppression by the single operational writer (ADR-007), **without** exactly-once transport — is a named **later ADR**, deferred to keep the first cut simple. Recorded here so the risk is explicit, not discovered.

## Consequences

- Simple first cut: dedup where it matters (uplink, alert state), tolerate duplicates elsewhere.
- Identity and uplink tokens already exist, so tightening idempotency later is additive, not a rewrite.

## Alternatives considered

- **Strict at-least-once with full idempotency everywhere** — deferred: unnecessary rigor for a lossy first cut; revisited with the durable ingestion tier.
