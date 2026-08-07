# ADR-011: Event Delivery, Identity and Idempotency Contract

**Status:** Accepted
**Date:** 2026-08-07

## Context

The ingestion log (ADR-005), the IPC boundary (ADR-003/004), the two SQLite writers (ADR-006/007) and MQTT store-and-forward (ADR-008) together form a chain where the same event is delivered more than once by design: replay-after-checkpoint re-delivers events, the replay→live handoff re-delivers around its watermark, and MQTT store-and-forward re-sends on reconnection. Without a single, explicit delivery guarantee and a stable event identity, "no silent gap" and "no duplicate finding" cannot both be true, and each component would invent its own dedup rule. This ADR fixes one contract the whole chain obeys.

## Decision

Guardian Sentinel's internal event pipeline is **at-least-once delivery with idempotent effect application, keyed on a stable event identity.** Exactly-once is neither claimed nor relied upon; correctness comes from idempotency, not from never re-delivering.

### Stable event identity

- Every ingestion event has the durable identity `(session generation, sequence number)` (ADR-004/005), where session generation is a monotonic counter persisted by `guardian-can`. This pair — stable across log rotation, prefix eviction, trace export and restart, not a bare sequence number — is the idempotency key for all downstream effects, including the uplink idempotency token.
- Derived records carry a **deterministic key** traceable to the event(s) that produced them: a telemetry row keys on `(event identity, signal)`; an observation on `(event identity, rule, signal)`; a finding on `(rule, entity, incident-open event identity)`; an alert transition on `(alert key, transition ordinal)`. Re-processing the same inputs yields the same keys.

### Idempotency obligations

- **Telemetry / observations:** re-applying an event must upsert on its deterministic key, never append a duplicate row and never double-count in any aggregate or downsample tier.
- **Findings / incidents:** promoting the same condition from the same triggering event must resolve to the same finding/incident, not a second one. First-occurrence evidence is preserved (see alert lifecycle, ADR-004/plan).
- **Alert transitions:** a transition is applied at most once per `(alert key, transition ordinal)`; replay of an already-applied transition is a no-op, so hysteresis and escalation state cannot be corrupted by re-delivery.
- **Outbound delivery:** each outbound message carries the finding/alert's stable key as an idempotency token so the backend can dedupe; re-sent messages after reconnection are duplicate-safe by that token.

### Ordering guarantee

- Effects are applied in event-identity order within a session and in log-append order across sessions (ADR-004). Idempotency covers re-delivery; **ordering** covers correctness of state machines (an alert clear must not be applied before its raise). Both hold simultaneously.

### Relationship to checkpointing

- The checkpoint may lag committed effects (ADR-005). The window between last-committed-effect and checkpoint is re-processed on restart; idempotency makes that re-processing safe. This is the sole reason at-least-once is acceptable rather than a liability.

### MQTT delivery guarantee (uplink)

- Uplink is store-and-forward at-least-once (ADR-008), duplicate-safe via the idempotency token above. MQTT QoS is an implementation detail of that guarantee, not the guarantee itself; the backend must dedupe on the token regardless of QoS.
- Uplink delivery state is owned by the operational writer (ADR-007); transmission/ack does **not** gate the local checkpoint (ADR-005).

## Consequences

- One dedup rule (idempotency key) serves replay, handoff, and uplink — no component invents its own.
- "No silent gap" (at-least-once) and "no duplicate finding" (idempotency) are jointly satisfiable and independently testable.
- Every derived record is traceable to its originating event identity, supporting evidence-linked findings (Phase 6).
- Effect application code must be written idempotently from the start; this is a design constraint on the rules engine and writers, not an afterthought.

## Alternatives considered

- **Exactly-once delivery** — rejected: unachievable across process restarts and an unreliable link without a distributed-transaction burden unjustified on a CM4; idempotency achieves the same observable result.
- **Per-component dedup** — rejected: divergent rules across replay/handoff/uplink guarantee inconsistency at exactly the incident bursts where correctness matters.
- **Checkpoint only after every effect (including telemetry) commits** — rejected: couples safety-relevant durability to high-volume telemetry batching, defeating ADR-006's write discipline.
