# ADR-005: Bounded Replayable Local Ingestion Log with Checkpointed Restart

**Status:** Accepted
**Date:** 2026-08-06

## Context

`guardian-core` will restart — for upgrades, crashes or watchdog action — while `guardian-can` continues receiving live traffic. Evidence captured during that window must not be lost, and core must be able to resume without double-processing or silent gaps. Raw CAN traffic is also required as replayable evidence around incidents and as the test harness input for the adapter and rules engine.

## Decision

`guardian-can` maintains a **bounded, rotated, compressed local ingestion log** of typed events (ADR-004 envelope format). This log is a **first-class replay source**, not merely an archive.

### Restart semantics

1. `guardian-can` never blocks live CAN receipt waiting for `guardian-core`.
2. Every ingestion event carries a durable session generation and a per-session sequence number (assigned at ingestion). The durable **event identity** used for checkpointing and idempotency is the pair `(session generation, sequence number)` (ADR-004) — stable across log rotation, prefix eviction and restart, and comparable across sessions by generation.
3. `guardian-core` durably records two processed positions (below) as event identities in its operational database, under the checkpoint-advancement rules.
4. On reconnecting, core requests available events strictly after its **resume position** = `min(safety checkpoint, telemetry watermark)`.
5. `guardian-can` replays from the resume position via iterative log-backed catch-up up to a **live threshold**, then hands off to live per the handoff protocol below.
6. If part of the requested range has expired from the bounded log, `guardian-can` emits an explicit **ingestion-gap event** covering the missing range; core records it as an evidence gap and raises the appropriate device-health observation.
7. Replay and live data pass through the **same decoder and processing path** in core. No separate replay code path is permitted.

### Checkpoint advancement rules (two watermarks)

A single ingestion event can produce effects in more than one durable store with different durability timing: the operational DB commits findings, alert transitions and incidents *immediately*, while the telemetry DB commits *batched* (ADR-006). A single "processed" checkpoint cannot honestly represent both — if it advanced on safety effects alone, an event whose telemetry was still in an uncommitted batch would fall *before* the resume position after a crash and its telemetry would be lost, never replayed. Core therefore keeps **two durable positions**:

- **Safety checkpoint** — advances only after an event's required durable safety effects have committed. "Required durable effects" are the immediate-durability writes of ADR-006: findings, alert transitions, incident state, bus-off, and configuration changes, plus enqueue to the durable outbound delivery queue (ADR-007). Actual MQTT transmission/ack does **not** gate it (store-and-forward, ADR-008/011).
- **Telemetry watermark** — advances only when a telemetry batch has committed, to the identity of the last event in the committed batch.

**Resume position = `min(safety checkpoint, telemetry watermark)`.** On restart core replays from there, so it re-covers every event whose telemetry had not yet committed as well as any whose safety effects had not. All effect application is **idempotent under the event identity** (ADR-011): re-processing the window between the two watermarks produces no duplicate finding, no duplicate alert transition, and no double-counted telemetry, while guaranteeing the previously-uncommitted telemetry is now written. No bounded telemetry loss is accepted; if a future decision ever chose to accept some, it would have to state and quantify that contract explicitly here.

Both positions are written as immediate-durability operational writes.

### Replay-to-live handoff protocol

Ingestion continues while core is catching up, and a long replay can produce more live events than any bounded IPC buffer can hold. The handoff therefore drains from the **canonical log by iterative catch-up**, and never assumes a live-tail buffer survives the replay:

1. **Successor operation.** Define `next(identity)` over event identities: within a session `(g, s) → (g, s+1)` while `s+1` exists in generation `g`; at a session boundary it advances to `(g′, s₀)` where `g′` is the least session generation greater than `g` that exists in the log and `s₀` is that session's first sequence. "After position P" always means the range beginning at `next(P)`; there is no bare `watermark + 1` across a session boundary.
2. **Catch-up loop.** From the resume position, `guardian-can` fixes an **end-of-range watermark** at the current log head and replays that range from the log. Because ingestion continues, the head has advanced by the time core finishes; core requests the next log-backed range `(last processed, new head]`. This repeats until the gap between core's position and the live head is within a defined **live threshold** (a bounded number of events / bounded time). Each range is served from the durable log, so replay depth is limited only by the log, not by any buffer.
3. **Live transition.** Once within the live threshold, core subscribes to the live IPC tail; the log writer releases newly durable events (ADR-003) starting at `next(core's last processed)`. Only this final, threshold-bounded gap is ever bridged by the in-memory IPC buffer, so the buffer can be small and fixed. If at any point the live tail outruns the buffer, core falls back to another log-backed catch-up range rather than dropping — the log is always the backstop.
4. **Crash safety.** Core acknowledges each processed range durably via its watermarks; if core dies mid-handoff, it resumes from `min(safety checkpoint, telemetry watermark)` — never from an in-memory position — and the loop repeats.
5. **Permitted duplication.** The only duplication is re-delivery at or before the resume position on a repeated handoff, absorbed by idempotency (ADR-011). Any other duplication, or any gap, is a defect.

### Evidence pinning (reverse control channel)

`guardian-can` owns the raw evidence, but `guardian-core` discovers the incident that must be pinned. The primary IPC is can→core; pinning therefore requires an explicit **core→can control channel** over the same Unix domain socket:

- Core issues a **pin request** naming a range by event identity `(from, to)` (or an open-ended "pin from here for N seconds/events"), with a client-assigned request ID.
- `guardian-can` responds with a **durable acknowledgement** once the range is marked pinned in its own durable pin index; the range is exempt from routine rotation/eviction until unpinned or until the pin quota forces eviction (below).
- **Race with rotation:** if any part of the requested range has already been evicted when the pin arrives, `guardian-can` pins what remains and returns the evicted sub-range so core can record an evidence gap — pinning never silently succeeds over missing data.
- **Pin quota:** pinned evidence has a hard bounded budget (ADR-013). When pinning would exceed it, eviction is **deterministic and safety-ordered**: the oldest pins for already-closed incidents are released first, active-incident pins last; every eviction of pinned evidence emits an ingestion-gap/eviction event so the loss is recorded. Pinning is never allowed to exhaust storage and stall ingestion.
- Pin and unpin are idempotent on the request ID; a repeated pin request after a core restart re-establishes the same pin without duplicating storage.
- **Startup reconciliation.** The pin *reference* lives in core's operational DB while the durable pin *index* lives in `guardian-can` (ADR-006); the two can drift across independent restarts. On (re)connection core **reissues all pins for still-open incidents** and `guardian-can` reports its current active pin index. Any discrepancy — a core-referenced pin missing from can's index, or a can-side pin with no live reference — is recorded as an explicit **evidence-health fault**, not silently reconciled, so an incident whose evidence has actually been lost cannot appear intact.

### Bounds and retention

- The log is size- and/or time-bounded with rotation and compression; exact bounds are configuration, tuned during Phase 4 soak testing against eMMC endurance and incident-evidence requirements.
- High-resolution raw evidence around incidents is preserved beyond routine rotation (incident snapshot pinning).
- Raw CAN traffic is **not** synchronously inserted into SQLite (see ADR-006); the ingestion log is the raw-evidence store.

### Test-harness role

The same log format and replay mechanism serve as the input for the Phase 2 trace library, Phase 3 adapter tests, and fault-injection testing. Recorded sessions from the Orion Jr 2 unit are stored in `traces/` in this format.

### Acceptance criteria (Phase 4)

- **Continuous high-rate reconnect:** sustained above-nominal input across a `guardian-core` restart produces no unmarked gap at the replay→live join, and the only duplicates observed are those permitted by the delivery contract (ADR-011).
- **Replay exceeds IPC buffer:** a replay whose backlog and duration exceed the live-tail buffer's capacity while ingestion continues completes via iterative log-backed catch-up with no gap and no buffer overrun; the buffer bridges only the final threshold-bounded tail.
- **Telemetry durability (no missing telemetry):** SIGKILL of core after the **safety checkpoint** advances but **before** the telemetry batch commits — on restart the telemetry for those events is present (resume from `min` watermark re-covers them) with no duplicate and no double-count.
- **Crash injection at each boundary:** SIGKILL of core (a) mid-replay, (b) after committing a finding but before safety-checkpoint advance, and (c) after checkpoint advance — each recovers with no lost finding, no duplicate finding, no duplicate alert transition, and no double-counted telemetry.
- **Expired range:** requesting a resume position older than the log's tail yields an ingestion-gap event for exactly the missing range and a device-health observation.
- **Pinning under rotation:** a pin request racing eviction pins the surviving range and reports the evicted sub-range; pin quota exhaustion evicts deterministically and emits eviction events.
- **Pin reconciliation:** induced drift between core's pin references and `guardian-can`'s pin index is detected at startup and raised as an evidence-health fault, never silently reconciled.

## Consequences

- Core restarts lose no evidence within log bounds; losses beyond bounds are explicit, ordered, alertable events.
- One decoder path means every recorded trace is automatically a regression test input.
- The safety checkpoint and telemetry watermark both live with core's operational state (ADR-006/007), keeping ownership clear; resume-from-`min` reflects real durability of *both* safety effects and telemetry, not mere consumption.
- The delivery/idempotency guarantee this relies on is specified in ADR-011; storage/pin quotas and exhaustion policy in ADR-013.
- Log bounds trade eMMC wear and storage against replay depth; this tuning is a named Phase 4 task.

## Alternatives considered

- **Core rejoins live only; gaps reconstructed ad hoc from archival traces** — rejected: creates a second, divergent processing path and unverifiable timelines.
- **Unbounded log** — rejected: violates bounded-behaviour principle; storage exhaustion is itself a safety-relevant failure.
