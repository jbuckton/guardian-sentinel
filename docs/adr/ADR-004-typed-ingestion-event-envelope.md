# ADR-004: Versioned Typed Ingestion-Event Envelope

**Status:** Accepted
**Date:** 2026-08-06

## Context

`guardian-can` forwards not just CAN frames but everything `guardian-core` needs to interpret them correctly: bus health transitions, interface restarts, clock corrections and ingestion-integrity signals. If these travel out-of-band, core cannot order them against telemetry, and incident timelines become unreliable.

## Decision

All data crossing the `guardian-can` → `guardian-core` boundary (live IPC and replay from the ingestion log) uses a single **versioned, typed event envelope**.

### Envelope fields (every event)

- Schema version
- Boot/session identity (see **Session identity and ordering** below)
- Monotonic per-session sequence number
- Event type
- Source interface (e.g. `can0`)
- Wall-clock receipt time
- Wall-clock confidence (see **Clock semantics and confidence** below)
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
8. **Session start** — first record of a `guardian-can` session: session ID, the session's `boot_id` (from the kernel), monotonic clock origin, and the previous session ID if one is known from durable state
9. **Session end** — clean-shutdown marker for a session, when one can be written; its absence marks the session as incomplete

### Session identity and ordering

A session ID is an **identity, not an ordering relation**. Sequence numbers are monotonic **only within a session** and reset when a new session begins. Therefore:

- Order **within** a session is defined by its sequence numbers, assigned at ingestion before any buffering, so ordering survives spooling and replay.
- Order **across** sessions is defined by the **append order of session-start records in the ingestion log**, not by comparing sequence numbers or timestamps between sessions. The log is the authority for "session A precedes session B."
- Each session carries the kernel `boot_id`, so sessions can be grouped by device boot. `guardian-can` and `guardian-core` restart independently; a `guardian-core` restart does not begin a new `guardian-can` session, and a `guardian-can` restart (new session) is always visible to core as a session-start record.
- A session lacking a session-end record is **incomplete**: it was truncated by crash, power loss, or kill. Core treats the boundary between an incomplete session and the next session as a potential evidence discontinuity and records it as such.
- "After checkpoint" (ADR-005) is defined against the pair `(session ordinal in log, sequence number)`, never against a bare sequence number, because sequence numbers are not comparable across sessions.

Monotonic time is valid only within a single boot; it **cannot** establish order across boots or sessions. Cross-boot correlation relies on log append order and, where available, wall-clock time qualified by its confidence.

Serialisation: MessagePack (or an equivalently simple framed binary format). Schema version is bumped on any incompatible change; core must reject unknown versions explicitly rather than guessing.

### Clock semantics and confidence

Wall-clock and physical-event ordering are separate concerns and must not be conflated:

- **Receipt time** is when `guardian-can` observed the event, not when the physical event occurred. The envelope timestamps observation only; any inference about physical-event time is `guardian-core`'s responsibility and must be labelled as such.
- Every event carries a **wall-clock confidence** qualifier: `unsynchronised` (no trusted time source yet this boot — e.g. before first NTP sync), `synchronised` (wall clock believed accurate), or `stepped` (a clock-adjustment event has been applied). Ordering and timeline claims must degrade gracefully when confidence is `unsynchronised`.
- Within a boot, **monotonic time is the only reliable ordering clock**; timelines are constructed on monotonic time and annotated with wall-clock time at the stated confidence.
- Clock-adjustment events (type 5) record old time, new time, and the monotonic time of the adjustment, so a timeline spanning an NTP step remains reconstructible on the monotonic axis.
- Timeline claims are bounded to what a single boot/session can prove; cross-boot timelines are presented as correlations qualified by clock confidence, never as exact orderings.

## Consequences

- Incident timelines can interleave frames, bus health and clock corrections deterministically.
- Replay and live processing share one input format, satisfying ADR-005's single-path rule.
- Clock adjustments become first-class evidence; timelines spanning an NTP step remain reconstructible using monotonic time.
- Overflow and gaps are visible, countable and alertable — evidence loss is never silent.

## Alternatives considered

- **Raw SocketCAN frames over IPC, health via logs** — rejected: unorderable, silent-loss-prone.
- **JSON envelope** — rejected: avoidable CPU/size overhead at CAN frame rates on a CM4.
