# ADR-004: Versioned Typed Ingestion-Event Envelope

**Status:** Accepted
**Date:** 2026-08-06

## Context

`guardian-can` forwards not just CAN frames but everything `guardian-core` needs to interpret them correctly: bus health transitions, interface restarts, clock corrections and ingestion-integrity signals. If these travel out-of-band, core cannot order them against telemetry, and incident timelines become unreliable.

## Decision

All data crossing the `guardian-can` → `guardian-core` boundary (live IPC and replay from the ingestion log) uses a single **versioned, typed event envelope**.

### Envelope fields (every event)

- Schema version
- **Durable session generation** and kernel `boot_id` (see **Session identity and ordering** below)
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
8. **Session start** — first record of a `guardian-can` session: durable session generation, kernel `boot_id`, monotonic clock origin, the previous generation if known from durable state, and a session-generation-discontinuity flag when generation state had to be recovered (see below)
9. **Session end** — clean-shutdown marker for a session, when one can be written; its absence marks the session as incomplete

### Session identity and ordering

A session's identity is a **durable session generation**, not its position in the log and not a bare sequence number. Sequence numbers are monotonic **only within a session** and reset when a new session begins.

**Durable session generation.** `guardian-can` maintains a strictly monotonic session-generation counter in persistent state (a small record, synced independently of the rotating log). On each new session it allocates `generation = last + 1` and stamps that generation into every event's envelope. Generations are never reused and never decrease. In the best-effort MVP (ADR-005) the counter is persisted **best-effort** — not `fsync`ed before the session's first event — and correctness on loss rests on the recovery rule below; strict *persist-before-release* is part of the durable tier (ADR-005), enabled when durability is turned up.

- **Stable identity.** The canonical **event identity** is the pair `(session generation, sequence number)`. Because generation lives in `guardian-can`'s durable state — not in the log's byte layout — this identity survives log rotation, prefix eviction, trace export, and process restart. It is the key used for checkpoints, pin ranges, derived-record keys, and uplink idempotency tokens (ADR-005/011).
- **Within-session order** is defined by sequence numbers, assigned at ingestion before any buffering, so ordering survives spooling and replay.
- **Cross-session order** is defined by **ascending session generation** (the log's append order of session-start records agrees with it and is the physical realisation). Sequence numbers and timestamps are never compared across sessions.
- Each session also carries the kernel `boot_id`, so sessions group by device boot. `guardian-can` and `guardian-core` restart independently: a `guardian-core` restart does not begin a new session; a `guardian-can` restart allocates the next generation and is always visible to core as a session-start record.
- A session lacking a session-end record is **incomplete** (truncated by crash, power loss, or kill). Core treats the boundary between an incomplete session and the next generation as a potential evidence discontinuity and records it as such.

**Recovery if generation state is lost or corrupt.** If the durable generation record is missing or fails validation at startup, `guardian-can` must not reuse or regress a generation. It allocates a new generation strictly greater than any it could previously have emitted, using a persisted high-water hint; if that is also unavailable, it derives a monotonic lower bound from another durable source (e.g. a boot counter, or a wall-clock-derived floor once time is trusted) and jumps the counter above it. It then emits a **session-generation-discontinuity** marker in the session-start payload so `guardian-core` records the uncertainty as an evidence-health fault rather than assuming contiguity.

Monotonic time is valid only within a single boot; it **cannot** establish order across boots or sessions. Cross-boot correlation relies on session generation and, where available, wall-clock time qualified by its confidence.

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
