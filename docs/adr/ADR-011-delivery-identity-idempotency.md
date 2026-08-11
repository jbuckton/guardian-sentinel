# ADR-011: Event Identity, Best-Effort Telemetry, and Tier-2 Replay Safety

**Status:** Accepted
**Date:** 2026-08-07

## Context

Best-effort delivery (ADR-005) plus MQTT store-and-forward (ADR-008) means an event can be delivered more than once (buffer re-read after a `guardian-core` restart, uplink resend) and sometimes zero times (an explicit gap). Duplicate *telemetry* is harmless. Duplicate or out-of-order *safety* effects are not: during restart catch-up, replaying a stale incident **close** against already-current state could transiently clear or reclose an active incident, or emit out-of-order safety-relevant outbound transitions — which can momentarily hide a real condition. So the two classes need different treatment, without resorting to exactly-once transport or durable raw telemetry.

## Decision

- **Event identity** is `(session id, sequence number)` (ADR-004): it labels events for ordering and cheap dedup.
- **Tier 0 — telemetry: best-effort, duplicate-tolerant.** Occasional duplicate or re-counted telemetry is acceptable in the first cut (the data is lossy anyway); upsert on identity where convenient. Strict telemetry idempotency is a later ADR.
- **Tier 2 — safety transitions: deterministically keyed + atomically deduped.** Findings, incident open/close, alert transitions, acknowledgements, device-health transitions, and safety-relevant outbound each carry a **deterministic effect identity** derived from their cause — e.g. finding `(rule, entity, opening-event identity)`, incident `(incident key, transition kind, ordinal)`, alert `(alert key, transition ordinal)` — **not** a random id, so a replay of the same cause yields the same key. The single **operational writer** (ADR-007) applies these with **atomic duplicate suppression** (unique key / insert-or-ignore), so re-delivery on restart is a no-op.
- **Output gating until convergence.** During restart catch-up (re-reading the buffered window), core does **not** emit safety-relevant outbound transitions or apply incident open/close as *live* until it has **converged to live**. Replayed transitions reconcile against current durable state — a close older than the current state is ignored, not applied — so a stale replayed close can never transiently clear or reopen an active incident, and no out-of-order safety uplink is emitted.
- **Uplink** carries the deterministic key as an idempotency token so the backend dedupes resends.

This needs **no exactly-once transport and no durable raw telemetry**: it is deterministic identity + single-writer atomicity + an output gate, all cheap on the low-volume Tier-2 changes. Strict global idempotency across every effect remains a later ADR alongside the durable ingestion tier.

## Consequences

- A restart cannot duplicate a finding, transiently clear/reopen an active incident, or emit out-of-order safety uplinks — the safety hole is closed without zero-loss machinery.
- Telemetry stays best-effort and duplicate-tolerant; the cost lands only on rare Tier-2 transitions.
- Identity and uplink tokens already exist, so tightening telemetry idempotency later is additive.

## Alternatives considered

- **Documenting duplicates as a visible-but-tolerated limitation** — rejected: a replayed stale close can *transiently clear an active incident*, so visibility alone does not prove no condition is hidden.
- **Exactly-once transport / durable raw telemetry** — rejected: unnecessary; deterministic identity + single-writer atomicity + output gating achieve Tier-2 safety without it.
