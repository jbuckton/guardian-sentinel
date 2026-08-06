# ADR-004: Versioned Typed Ingestion-Event Envelope

**Status:** Accepted
**Date:** 2026-08-06

## Context

`guardian-can` forwards not just CAN frames but everything `guardian-core` needs to interpret them correctly: bus health transitions, interface restarts, clock corrections and ingestion-integrity signals. If these travel out-of-band, core cannot order them against telemetry, and incident timelines become unreliable.

## Decision

All data crossing the `guardian-can` → `guardian-core` boundary (live IPC and replay from the ingestion log) uses a single **versioned, typed event envelope**.

### Envelope fields (every event)

- Schema version
- Boot/session identity
- Monotonic per-session sequence number
- Event type
- Source interface (e.g. `can0`)
- Wall-clock receipt time
- Monotonic receipt time
- Type-specific payload

### Ordered event types

1. **CAN frame** — CAN ID, payload bytes, DLC/flags
2. **CAN state change** — controller state transitions (e.g. error-active / error-passive / bus-off), as reported by the interface
3. **CAN error** — error counters and error-frame information as exposed by SocketCAN
4. **CAN interface restart** — interface down/up or controller restart, with reason where known
5. **Clock adjustment** — wall-clock corrections (e.g. NTP step after connectivity), recording old time, new time and monotonic time of the adjustment
6. **Ingestion overflow** — bounded buffer/spool overflow: count of dropped events and the affected sequence range
7. **Ingestion gap** — an explicit evidence-gap marker emitted when a requested replay range has expired from the log (ADR-005)

Events are strictly ordered by session ID + sequence number. Sequence numbers are assigned at ingestion, before any buffering, so ordering survives spooling and replay.

Serialisation: MessagePack (or an equivalently simple framed binary format). Schema version is bumped on any incompatible change; core must reject unknown versions explicitly rather than guessing.

## Consequences

- Incident timelines can interleave frames, bus health and clock corrections deterministically.
- Replay and live processing share one input format, satisfying ADR-005's single-path rule.
- Clock adjustments become first-class evidence; timelines spanning an NTP step remain reconstructible using monotonic time.
- Overflow and gaps are visible, countable and alertable — evidence loss is never silent.

## Alternatives considered

- **Raw SocketCAN frames over IPC, health via logs** — rejected: unorderable, silent-loss-prone.
- **JSON envelope** — rejected: avoidable CPU/size overhead at CAN frame rates on a CM4.
