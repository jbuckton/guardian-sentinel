# ADR-005: Bounded Replayable Local Ingestion Log with Checkpointed Restart

**Status:** Accepted
**Date:** 2026-08-06

## Context

`guardian-core` will restart — for upgrades, crashes or watchdog action — while `guardian-can` continues receiving live traffic. Evidence captured during that window must not be lost, and core must be able to resume without double-processing or silent gaps. Raw CAN traffic is also required as replayable evidence around incidents and as the test harness input for the adapter and rules engine.

## Decision

`guardian-can` maintains a **bounded, rotated, compressed local ingestion log** of typed events (ADR-004 envelope format). This log is a **first-class replay source**, not merely an archive.

### Restart semantics

1. `guardian-can` never blocks live CAN receipt waiting for `guardian-core`.
2. Every ingestion event carries a session identity and a per-session sequence number (assigned at ingestion). The durable **event identity** used for checkpointing and idempotency is the pair `(session ordinal in log, sequence number)` — a bare sequence number is not comparable across sessions (ADR-004).
3. `guardian-core` durably records its processed checkpoint as that event-identity pair in its operational database, under the checkpoint-advancement rules below.
4. On reconnecting, core requests available events strictly after its checkpoint.
5. `guardian-can` replays the requested range from the ingestion log up to a declared **end-of-replay watermark**, then hands off to live per the handoff protocol below.
6. If part of the requested range has expired from the bounded log, `guardian-can` emits an explicit **ingestion-gap event** covering the missing range; core records it as an evidence gap and raises the appropriate device-health observation.
7. Replay and live data pass through the **same decoder and processing path** in core. No separate replay code path is permitted.

### Checkpoint advancement rules

A single ingestion event can produce effects in more than one durable store: the telemetry DB, the operational DB (findings, alert transitions, incidents), and outbound delivery state (ADR-006/007). A crash between those writes must never leave the checkpoint claiming an event is done when its safety-relevant effects are not durable.

- The checkpoint for an event may advance **only after all of that event's required durable effects have committed.** "Required durable effects" are the immediate-durability writes of ADR-006: findings, alert transitions, incident state, bus-off, and configuration changes.
- Batched, downsamplable telemetry writes (ADR-006) are **not** required effects for checkpoint advancement; on replay they are re-derived idempotently (see ADR-011). The checkpoint therefore reflects safety-relevant durability, not every telemetry row.
- Enqueuing to the outbound MQTT delivery queue is a durable operational write (owned per ADR-007); it counts as a required effect. Actual MQTT transmission/acknowledgement does **not** gate the checkpoint (delivery is store-and-forward, ADR-008/011).
- Because the checkpoint may lag committed effects, **all effect application must be idempotent under the event-identity key** (ADR-011). Re-processing the window between last-committed-effect and checkpoint on restart must produce no duplicate findings, no duplicate alert transitions, and no double-counted telemetry.
- Checkpoint writes are themselves immediate-durability operational writes.

### Replay-to-live handoff protocol

Ingestion continues while core is catching up, so the replay range and the live tail must be joined without a gap and without an unbounded race:

1. When core requests events after its checkpoint, `guardian-can` fixes an **end-of-replay watermark** at the current log head (an event identity) and replays `(checkpoint, watermark]` from the log.
2. Events that arrive **after** the watermark are appended to the log as normal and buffered for IPC; they are the live tail that will follow the replayed range in order.
3. Core processes the replayed range in order up to the watermark, then transitions to consuming the live tail beginning at `watermark + 1`. Because both come from the same ordered log identities, the join is exact: no event between watermark and live resumption is skipped or reordered.
4. Core acknowledges reaching the watermark; the handoff is complete only after that acknowledgement. If core dies mid-replay, its checkpoint is unchanged (or advanced only per the rules above) and the whole protocol repeats from the durable checkpoint — never from an in-memory position.
5. The only permitted duplication is re-delivery of events at or before the checkpoint on a repeated handoff, which idempotency (ADR-011) absorbs. Any other duplication or any gap is a defect.

### Evidence pinning (reverse control channel)

`guardian-can` owns the raw evidence, but `guardian-core` discovers the incident that must be pinned. The primary IPC is can→core; pinning therefore requires an explicit **core→can control channel** over the same Unix domain socket:

- Core issues a **pin request** naming a range by event identity `(from, to)` (or an open-ended "pin from here for N seconds/events"), with a client-assigned request ID.
- `guardian-can` responds with a **durable acknowledgement** once the range is marked pinned in its own durable pin index; the range is exempt from routine rotation/eviction until unpinned or until the pin quota forces eviction (below).
- **Race with rotation:** if any part of the requested range has already been evicted when the pin arrives, `guardian-can` pins what remains and returns the evicted sub-range so core can record an evidence gap — pinning never silently succeeds over missing data.
- **Pin quota:** pinned evidence has a hard bounded budget (ADR-013). When pinning would exceed it, eviction is **deterministic and safety-ordered**: the oldest pins for already-closed incidents are released first, active-incident pins last; every eviction of pinned evidence emits an ingestion-gap/eviction event so the loss is recorded. Pinning is never allowed to exhaust storage and stall ingestion.
- Pin and unpin are idempotent on the request ID; a repeated pin request after a core restart re-establishes the same pin without duplicating storage.

### Bounds and retention

- The log is size- and/or time-bounded with rotation and compression; exact bounds are configuration, tuned during Phase 4 soak testing against eMMC endurance and incident-evidence requirements.
- High-resolution raw evidence around incidents is preserved beyond routine rotation (incident snapshot pinning).
- Raw CAN traffic is **not** synchronously inserted into SQLite (see ADR-006); the ingestion log is the raw-evidence store.

### Test-harness role

The same log format and replay mechanism serve as the input for the Phase 2 trace library, Phase 3 adapter tests, and fault-injection testing. Recorded sessions from the Orion Jr 2 unit are stored in `traces/` in this format.

### Acceptance criteria (Phase 4)

- **Continuous high-rate reconnect:** sustained above-nominal input across a `guardian-core` restart produces no unmarked gap at the replay→live join, and the only duplicates observed are those permitted by the delivery contract (ADR-011).
- **Crash injection at each boundary:** SIGKILL of core (a) mid-replay, (b) after committing a finding but before checkpoint advance, and (c) after checkpoint advance — each recovers with no lost finding, no duplicate finding, no duplicate alert transition, and no double-counted telemetry.
- **Expired range:** requesting a checkpoint older than the log's tail yields an ingestion-gap event for exactly the missing range and a device-health observation.
- **Pinning under rotation:** a pin request racing eviction pins the surviving range and reports the evicted sub-range; pin quota exhaustion evicts deterministically and emits eviction events.

## Consequences

- Core restarts lose no evidence within log bounds; losses beyond bounds are explicit, ordered, alertable events.
- One decoder path means every recorded trace is automatically a regression test input.
- Checkpoint persistence lives with core's operational state (ADR-006/007), keeping ownership clear; its advancement is gated on durable safety-relevant effects, so it reflects real durability, not mere consumption.
- The delivery/idempotency guarantee this relies on is specified in ADR-011; storage/pin quotas and exhaustion policy in ADR-013.
- Log bounds trade eMMC wear and storage against replay depth; this tuning is a named Phase 4 task.

## Alternatives considered

- **Core rejoins live only; gaps reconstructed ad hoc from archival traces** — rejected: creates a second, divergent processing path and unverifiable timelines.
- **Unbounded log** — rejected: violates bounded-behaviour principle; storage exhaustion is itself a safety-relevant failure.
