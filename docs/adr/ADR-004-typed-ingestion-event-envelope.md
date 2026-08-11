# ADR-004: Versioned Typed Ingestion-Event Envelope

**Status:** Accepted
**Date:** 2026-08-06

## Context

`guardian-can` forwards not just CAN frames but everything `guardian-core` needs to interpret them correctly: bus health transitions, interface restarts, clock corrections and ingestion-integrity signals. If these travel out-of-band, core cannot order them against telemetry, and incident timelines become unreliable.

## Decision

All data crossing the `guardian-can` → `guardian-core` boundary (live IPC and replay from the ingestion log) uses a single **versioned, typed event envelope**.

### Envelope fields (every event)

- Schema version
- **Session id** (collision-resistant, allocated at session start) and kernel `boot_id` (see **Session identity and ordering** below)
- Per-session sequence number
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
8. **Session start** — first record of a `guardian-can` session: session id, kernel `boot_id`, monotonic clock origin, and the previous session id if known
9. **Session end** — clean-shutdown marker for a session; its absence marks the session as incomplete

### Session identity and ordering

A session's identity is a **collision-resistant session id** (a UUID, or `boot_id` + a start nonce) allocated by `guardian-can` at session start. It is *identity*, not an ordering counter — deliberately not a durable monotonic generation, to avoid a fragile "prove this value exceeds every previous one" recovery path. Because each id is freshly random, it can never collide with a prior session, so a re-read after a restart can never be mistaken for — or suppress — a genuinely new event.

- **Within a session**, order is the per-session sequence number (assigned at ingestion before buffering); sequence numbers reset per session and are compared only within one.
- **Across sessions**, order is best-effort by session-start time — monotonic within a boot, wall-clock (at its confidence) across boots. The MVP accepts approximate cross-session ordering, consistent with tolerating missed data (ADR-005).
- `boot_id` groups sessions by device boot. `guardian-can` and `guardian-core` restart independently; a new `guardian-can` session always reaches core as a session-start record.
- A session with no session-end record is **incomplete** (crash/power-loss); core marks the boundary as a possible evidence discontinuity.

Serialisation: MessagePack (or an equivalent framed binary format). Schema version is bumped on any incompatible change; core must reject unknown versions explicitly rather than guessing.

### Clock semantics and confidence

- **Receipt time** is when `guardian-can` observed the event, not when the physical event occurred; any inference about physical-event time is `guardian-core`'s job and must be labelled as such.
- Every event carries a **wall-clock confidence** qualifier — `unsynchronised` / `synchronised` / `stepped` — and timeline claims must degrade gracefully when it is `unsynchronised`.
- Within a boot, **monotonic time is the only reliable ordering clock**; timelines are built on it and annotated with wall-clock time at the stated confidence. Clock-adjustment events (type 5) record old/new/monotonic time so a timeline spanning an NTP step stays reconstructible.

## Consequences

- Incident timelines can interleave frames, bus health and clock corrections deterministically.
- Replay and live processing share one input format, satisfying ADR-005's single-path rule.
- Clock adjustments become first-class evidence; timelines spanning an NTP step remain reconstructible using monotonic time.
- Sequence numbers make most loss detectable as gaps; gaps degrade health (ADR-012). Some loss may be unquantified — an accepted first-cut limitation (ADR-005), not a claim of exactness.

## Alternatives considered

- **Raw SocketCAN frames over IPC, health via logs** — rejected: unorderable, silent-loss-prone.
- **JSON envelope** — rejected: avoidable CPU/size overhead at CAN frame rates on a CM4.
