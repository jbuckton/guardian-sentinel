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

1. The **receive loop** assigns the event identity `(session generation, sequence number)` (ADR-004), stamps wall-clock and monotonic receipt time, and places the event into the in-memory ring buffer, from which it is offered to the IPC queue and to the best-effort on-disk log writer. It performs no synchronous durable I/O, so SocketCAN never blocks on storage.
2. When any bounded queue (IPC or log) is full, or storage cannot keep up, events are dropped. The loop **keeps assigning sequence numbers to dropped events** (it never stops counting), so every loss appears as a **sequence discontinuity**.
3. The receiver synthesises an **ingestion-gap / ingestion-overflow event** (ADR-004) for exactly the discontinuous range; core records the evidence gap, marks ingestion degraded, and health degrades (ADR-012). Loss is thus **bounded, counted, ordered, and alertable — never silent**, even though it is not prevented.

This makes explicitness, not durability, the invariant: the device never presents a gap as healthy data. Turning durability *up* (durable-append-before-IPC, an emergency journal for disk-full, checkpointed zero-loss replay) is the documented durable-tier upgrade in ADR-005, not MVP scope.

Rotation and compression run without dropping the live ring: a partially written segment is detectable and skipped on restart, not replayed as valid events.

### Acceptance criteria (Phase 4)

- Sustained input above nominal Jr 2 frame rate with `guardian-core` stopped: no receive-loop stall; the in-buffer window is delivered on reconnect, and anything beyond the buffer is reported as an explicit gap event — no silent loss.
- Queue/storage saturation during ingestion: dropped ranges surface as sequence discontinuities → synthesised gap/overflow events; device-health shows degraded; ingestion never stalls.
- SIGKILL of `guardian-can` during segment rotation: on restart the log opens cleanly, the partial segment is skipped, no corrupt event is replayed, and the discontinuity across the kill is reported as a gap.
- `guardian-core` restart mid-stream: core resumes live, the in-buffer catch-up replays through the same decoder path, and the un-buffered portion is a marked gap (no zero-loss claim).

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
