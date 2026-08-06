# ADR-005: Bounded Replayable Local Ingestion Log with Checkpointed Restart

**Status:** Accepted
**Date:** 2026-08-06

## Context

`guardian-core` will restart — for upgrades, crashes or watchdog action — while `guardian-can` continues receiving live traffic. Evidence captured during that window must not be lost, and core must be able to resume without double-processing or silent gaps. Raw CAN traffic is also required as replayable evidence around incidents and as the test harness input for the adapter and rules engine.

## Decision

`guardian-can` maintains a **bounded, rotated, compressed local ingestion log** of typed events (ADR-004 envelope format). This log is a **first-class replay source**, not merely an archive.

### Restart semantics

1. `guardian-can` never blocks live CAN receipt waiting for `guardian-core`.
2. Every ingestion event carries a session ID and sequence number (assigned at ingestion).
3. `guardian-core` durably records its processed checkpoint (session ID + sequence number) in its operational database.
4. On reconnecting, core requests available events after that checkpoint.
5. `guardian-can` replays the requested range from the ingestion log, then core transitions to live processing.
6. If part of the requested range has expired from the bounded log, `guardian-can` emits an explicit **ingestion-gap event** covering the missing range; core records it as an evidence gap and raises the appropriate device-health observation.
7. Replay and live data pass through the **same decoder and processing path** in core. No separate replay code path is permitted.

### Bounds and retention

- The log is size- and/or time-bounded with rotation and compression; exact bounds are configuration, tuned during Phase 4 soak testing against eMMC endurance and incident-evidence requirements.
- High-resolution raw evidence around incidents is preserved beyond routine rotation (incident snapshot pinning).
- Raw CAN traffic is **not** synchronously inserted into SQLite (see ADR-006); the ingestion log is the raw-evidence store.

### Test-harness role

The same log format and replay mechanism serve as the input for the Phase 2 trace library, Phase 3 adapter tests, and fault-injection testing. Recorded sessions from the Orion Jr 2 unit are stored in `traces/` in this format.

## Consequences

- Core restarts lose no evidence within log bounds; losses beyond bounds are explicit, ordered, alertable events.
- One decoder path means every recorded trace is automatically a regression test input.
- Checkpoint persistence lives with core's operational state (ADR-006/007), keeping ownership clear.
- Log bounds trade eMMC wear and storage against replay depth; this tuning is a named Phase 4 task.

## Alternatives considered

- **Core rejoins live only; gaps reconstructed ad hoc from archival traces** — rejected: creates a second, divergent processing path and unverifiable timelines.
- **Unbounded log** — rejected: violates bounded-behaviour principle; storage exhaustion is itself a safety-relevant failure.
