# ADR-005: Bounded Ingestion Buffer — Tiered Durability, Explicit Gaps, Replay-Based Testing

**Status:** Accepted
**Date:** 2026-08-09
**Supersedes the durability stance of the 2026-08-06 draft** ("no evidence loss within bounds, checkpointed zero-loss replay"), which imposed per-event durability unjustified for the MVP and hostile to eMMC endurance. The envelope, sequence numbering, replay-through-the-production-path testing and the pin control channel are retained; the zero-loss *guarantee* is replaced by a tunable durability model whose MVP default is best-effort with explicit gaps.

## Context

`guardian-core` will restart (upgrades, crashes, watchdog) while `guardian-can` keeps receiving live traffic. The earlier draft required every event to be durably logged before use so a restart could lose nothing — but that forces `fsync` at CAN frame rates, which is the dominant eMMC-wear risk on the CM4 (small synchronous writes → large write amplification), and it is not what safety actually requires.

The safety property is **explicitness, not durability**: a missed window is safe *if it is known to be missed*. During a gap the health state degrades to `unknown`/`degraded` (ADR-012), so the device never reports health it does not have. That is categorically different from silently carrying stale data forward. Durability buys *evidence completeness*, which is valuable but is a tunable quality knob, not a safety invariant — and different data classes justify very different amounts of it.

## Decision

`guardian-can` maintains a **bounded ingestion buffer**: a RAM ring of recent typed events (ADR-004 envelope) backed by a bounded, rotated, compressed on-disk log written **best-effort** (coarse batched flushes; **no per-event `fsync`** in the MVP). Durability is applied per data class, and is a **configuration knob**, not a fixed guarantee.

### Durability tiers (MVP defaults; all tunable)

- **Tier 0 — CAN stream / telemetry (best-effort).** Loss is permitted but **never silent.** Because every event carries a per-session sequence number (ADR-004), any loss shows as a **sequence discontinuity**; the receiver synthesises an **ingestion-gap event** for exactly the missing range, and health degrades accordingly (ADR-012). This is the high-volume path and the one that must not `fsync` per frame.
- **Tier 1 — Incident evidence (pre-roll, persist on trigger).** `guardian-can` keeps a RAM **pre-roll** ring of the last *N* seconds/events. When `guardian-core` detects a finding it requests, over the reverse channel, that the pre-roll plus a following incident window be persisted (pinned). In the MVP this persist is **best-effort** (no `fsync` — see "Deferred: durable tier"); it still captures the run-up to every *detected* incident at near-zero steady-state write cost. An unlucky crash exactly at incident onset may lose pre-roll — accepted for the first pilot, revisited when the durable tier lands.
- **Tier 2 — Operational safety state (durable).** Current alert/incident state, acknowledgements, configuration, and decoder/profile version are **durably written on change** (ADR-006 operational writer). This is kilobytes changing rarely, so its `fsync` cost is negligible — and forgetting an active alarm across a reboot is a real safety regression, not a "missed window." This tier stays durable even in the MVP.

### Restart semantics (MVP: best-effort resume + explicit gap)

1. `guardian-can` never blocks live CAN receipt waiting for `guardian-core`.
2. On reconnect, `guardian-can` replays whatever remains in its buffer after `guardian-core`'s last-seen position, then transitions to live. Core's last-seen position is a **lightweight, loosely-persisted** marker — not a durably-`fsync`ed checkpoint in the MVP.
3. Anything the buffer no longer holds (evicted, or lost because guardian-can itself restarted) is covered by an explicit **ingestion-gap event**; core records the evidence gap and raises the device-health observation. There is no attempt to guarantee zero loss across the outage.
4. **Replay and live data pass through the same decoder and processing path** in core. No separate replay code path is permitted — this is what keeps recorded traces valid as tests and is retained unchanged.

Because loss is possible, `guardian-core` writes all effects **idempotently under event identity** (ADR-011): buffer replay and MQTT reconnection can re-deliver events, and re-delivery must never double-count telemetry or duplicate a finding/alert transition. Idempotency is required in every tier; durability is not.

### Evidence-pin control channel (retained, best-effort in MVP)

`guardian-can` owns the raw evidence; `guardian-core` detects the incident. Pinning uses an explicit **core→can control channel** over the same socket:

- Core issues a **pin request** naming a range by event identity (or "pin the pre-roll plus the next window") with a request ID; `guardian-can` acknowledges and exempts that range from routine eviction.
- If part of the range is already gone (Tier 0 best-effort), `guardian-can` reports the missing sub-range so core records an evidence gap — pinning never silently succeeds over absent data.
- Pins are idempotent on the request ID; pinned evidence is bounded by the storage quota (ADR-013) and evicted in a deterministic, safety-ordered way (closed incidents first) with recorded eviction/gap events.
- **Startup reconciliation:** on (re)connection core reissues pins for open incidents and `guardian-can` reports its active pin set; any drift becomes an explicit **evidence-health fault**, never silently reconciled.

### Bounds and retention

- The buffer/log is size- and/or time-bounded with rotation and compression; bounds are configuration, tuned in Phase 4 against eMMC endurance vs. incident-evidence needs.
- Raw CAN traffic is **never** synchronously inserted into SQLite (ADR-006); the ingestion buffer/log is the raw-evidence store.

### Test-harness role (unchanged)

The envelope format and replay mechanism are the input for the Phase 2 trace library, Phase 3 adapter tests, and fault injection. Recorded Jr 2 sessions live in `traces/` in this format. A trace file is a *deliberate* durable capture (a dev activity), independent of runtime Tier 0 durability.

### Deferred: durable tier (future config / ADR)

Raising Tier 0/1 to a **zero-loss** guarantee — durable-append-before-IPC, a durably-`fsync`ed checkpoint (or dual safety/telemetry watermarks with `min`-resume), iterative log-backed catch-up beyond the live buffer, and an emergency journal for disk-full — is a **documented upgrade path**, not MVP scope. It is enabled by turning the durability knob up (and accepting the `fsync`/endurance cost) and is gated on a future decision when a deployment needs guaranteed evidence continuity. The envelope, sequence numbering, event identity `(session generation, sequence)`, and pin channel already in place make that upgrade additive rather than a redesign.

## Consequences

- **eMMC wear drops by orders of magnitude:** steady state is memory-speed buffering with coarse flushes; `fsync` happens only on rare Tier-2 safety-state changes and (optionally) Tier-1 incident persistence — not at frame rate.
- Core restarts may lose the in-flight window; that loss is **explicit, ordered, and alertable** (gap events + degraded health), never silent — consistent with the fail-explicitly principle.
- One decoder path means every recorded trace remains a regression-test input.
- The MVP carries far less machinery (no two-watermark min-resume, no emergency journal, no iterative catch-up); those are documented and deferred, so turning durability up later is additive.
- Idempotency (ADR-011) is doing the heavy lifting that durability used to: it makes best-effort re-delivery safe.

## Alternatives considered

- **Per-event durable log with checkpointed zero-loss replay (the earlier draft)** — deferred, not adopted for MVP: it protects evidence completeness the MVP does not require while imposing frame-rate `fsync` that threatens eMMC life. Retained as the documented durable-tier upgrade.
- **Raw frames over IPC, no sequence numbers, health via logs** — rejected: makes loss *silent and unorderable*. We keep the sequence-numbered envelope precisely so best-effort loss stays detectable and ordered.
- **Unbounded buffer** — rejected: bounded behaviour is a safety property (ADR-013).
