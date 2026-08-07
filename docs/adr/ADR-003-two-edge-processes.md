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

### Canonical ingestion path

The ingestion log (ADR-005) — not the IPC socket — is the canonical, authoritative record. The receive loop's ordering of durable operations is:

1. Assign session ID + sequence number and stamp wall-clock and monotonic receipt time (ADR-004).
2. **Append the envelope to the ingestion log before offering it to the IPC send queue.** An event that is durably logged but not yet delivered over IPC is never lost: `guardian-core` will obtain it by replay-after-checkpoint (ADR-005). IPC is a low-latency fast path over the log, not a second source of truth.
3. Offer the event to the bounded IPC send queue. If the queue is full, drop from the **IPC path only** (core recovers the event by replay); the log append must already have succeeded.

The log append itself must not block the receive loop indefinitely. The log writer runs behind its own bounded queue; the receive loop hands off and continues. If the log-writer queue is full, or the append cannot complete (disk full, slow storage, rotation/compression stall), the loop:

- counts the affected events and the affected sequence range,
- emits an **ingestion-overflow event** (ADR-004) recording that count and range,
- marks ingestion degraded in device-health,

and continues receiving — it never stalls SocketCAN waiting for storage. Loss of durability is thus always bounded, counted, ordered, and alertable; it is never silent.

Rotation and compression run without dropping the tail: the active segment remains appendable while a prior segment compresses, and termination during rotation must leave a recoverable log (a partially written segment is detectable and skipped on restart, not replayed as valid events).

### Acceptance criteria (Phase 4)

- Sustained input above nominal Jr 2 frame rate with `guardian-core` stopped: no receive-loop stall; every event either delivered on reconnect via replay or accounted for by an ingestion-overflow event.
- Disk-full and artificially slowed storage during ingestion: overflow events emitted with correct counts/ranges; no silent loss; device-health shows degraded.
- Process kill (SIGKILL) of `guardian-can` during segment rotation: on restart the log opens cleanly, the partial segment is skipped, and no corrupt event is replayed.
- IPC send-queue saturation with the log healthy: dropped IPC events are all recovered by core via replay-after-checkpoint; final processed set equals the logged set (subject to the delivery contract in ADR-011).

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
