# ADR-003: Two Edge Processes — `guardian-can` and `guardian-core`

**Status:** Accepted
**Date:** 2026-08-06

## Context

Live CAN receipt is the one activity on the edge device that must never stall: missed frames are lost evidence. Database writes, MQTT delivery, rule evaluation, HTTP handling and AI-assisted diagnostics all have unpredictable latency. A single process mixing these concerns makes it easy for a slow consumer to block ingestion.

## Decision

The edge runtime consists of exactly **two primary processes**, each a systemd service.

### `guardian-can`

Responsible for:
- SocketCAN ingestion
- Receipt timestamps (wall-clock and monotonic)
- Frame sequence numbers and session identity
- Basic CAN health (error counters, state changes, bus-off, interface restarts)
- Rolling trace capture (bounded, rotated, compressed)
- Bounded buffering / local spooling
- Forwarding typed ingestion events over local IPC (Unix domain socket)

`guardian-can` must **not** perform battery decoding, database writes, MQTT publishing or rule evaluation.

### `guardian-core`

Responsible for:
- Orion Jr 2 decoding (sole adapter, ADR-001) and thermistor-broadcast decoding
- State assembly and signal quality
- Deterministic observations and findings
- Alert and incident lifecycle
- SQLite persistence (ADR-006, ADR-007)
- MQTT delivery
- Local API
- Device-health processing

### Non-blocking rules

The SocketCAN receive loop must never block on core processing, SQLite, MQTT, HTTP, dashboard access, or Claude/AI services. All downstream paths use bounded queues. If a consumer cannot keep up: record consumer lag; spool to the bounded local log (ADR-005); mark ingestion degraded; count and expose dropped frames; never silently lose evidence.

### Ingestion path (best-effort with explicit gaps — MVP)

The ingestion buffer (ADR-005) is the raw-evidence record; the MVP writes it **best-effort** and does **not** gate IPC on durable persistence (per-frame `fsync` is the dominant eMMC-wear risk and is deliberately avoided). The pipeline is:

1. The **receive loop** assigns the event identity `(session id, sequence number)` (ADR-004), stamps receipt time, and places the event into the ring buffer, from which it is offered to the IPC queue and the best-effort on-disk log writer. It performs no synchronous durable I/O, so SocketCAN never blocks on storage.
2. When a bounded queue (IPC or log) is full, or storage cannot keep up, events are dropped. The loop keeps assigning sequence numbers, so most loss appears as a **sequence discontinuity**, and IPC-path vs log-path loss are counted separately.
3. The receiver flags a **gap** (ADR-004); core records it, marks ingestion degraded, and health/data-confidence degrade (ADR-012).

**Loss is classified, and the invariant is scoped to what is detectable:**

- **Known loss** — a sequence discontinuity or a queue/log drop counter: the range is flagged as a gap (open-ended / unknown-extent markers are supported).
- **Inferred loss** — `guardian-core` knows the profile's configured broadcasts and their cadence (ADR-010); silence past a configured interval, or an incomplete session (missing session-end), is inferred as a gap even with no discontinuity marker.
- **Undetectable loss** — e.g. a dropped session tail with nothing after it, or a gap marker lost on the same saturated path — cannot be seen at the time. This is an **honest MVP limitation**, not a claim of completeness.

**Invariant: known or inferred loss never appears healthy** — either forces data-confidence down and invalidates `healthy` (ADR-012). Most silence becomes *inferred* within a broadcast interval, bounding the undetectable case. Explicitness, not durability, is what the device relies on.

**Ownership:** `guardian-can` owns capture and IPC/log drop counters (known loss visible at the source); `guardian-core` owns envelope and expected-broadcast coherence interpretation and the resulting data-confidence state (inferred loss).

Rotation and compression run without dropping the live ring: a partially written segment is detectable and skipped on restart, not replayed as valid events.

### Acceptance criteria (Phase 4)

- Sustained input at/above nominal Jr 2 frame rate: the receive loop keeps up with the bus and never stalls; drops (if any) surface as gaps.
- Queue/storage saturation: dropped ranges surface as gaps (exact where sequence-derivable, open-ended otherwise), IPC vs log loss counted separately; health/data-confidence degrade; ingestion never stalls.
- **Inferred-loss detection:** with no sequence discontinuity available (dropped session tail, frames while `guardian-can` down, simultaneous can/core restart), core still infers a gap from missing expected broadcasts within their configured interval / incomplete session, and degrades data-confidence — verified by failure injection. Undetectable residual loss is acknowledged, not claimed covered.
- SIGKILL of `guardian-can` during rotation: on restart the log opens cleanly, the partial segment is skipped, no corrupt event is replayed, and the discontinuity is reported as a gap.
- `guardian-core` restart mid-stream: core resumes from the last-seen marker through the same decoder path; the un-buffered portion is a marked gap (no zero-loss claim).

### IPC

Unix domain socket, framed binary protocol (MessagePack or equivalent), carrying the versioned typed event envelope defined in ADR-004.

### Deployment principle

Begin with these two processes, not a microservice architecture. Split storage, uplink or analysis into separate services only when testing demonstrates a concrete isolation, performance or lifecycle need — via a new ADR.

## Consequences

- Ingestion survives `guardian-core` restarts, upgrades and stalls; restart semantics are defined in ADR-005.
- CAN health events must travel in-band with frames (ADR-004) so core can order them against telemetry.
- Two services to supervise, watchdog and health-check; both report into device-health.

## Alternatives considered

- **Single process with internal threads** — rejected: one runtime fault or GIL/lock stall can take out ingestion and evidence capture together.
- **Microservices per concern** — rejected: unjustified operational complexity on a single CM4.
