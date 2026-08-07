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

The ingestion log (ADR-005) — not the IPC socket — is the canonical, authoritative record. **Durable append is the gate for IPC visibility, and queue admission is not durability.** The pipeline is:

1. The **receive loop** assigns the event identity `(session generation, sequence number)` (ADR-004) and stamps wall-clock and monotonic receipt time, then enqueues the event to the **log writer's** bounded queue and returns immediately. It performs no durable I/O itself, so SocketCAN never blocks on storage. Enqueuing is *admission to the log writer*, not a durability guarantee.
2. The **log writer** durably appends the event to the ingestion log. **Only after the append is confirmed durable** does the log writer release the event to the IPC send queue. Consequently every event core can ever see over IPC is already durably logged, and an event durably logged but not yet delivered over IPC is recoverable by replay-after-checkpoint (ADR-005). IPC is a fast path over the log, never a second source of truth.
3. If the IPC send queue is full, the event is dropped **from the IPC path only** — it is already durable, so core recovers it by replay. This drop is benign and needs no gap marker.

**When the log itself is the failed path** (log-writer queue saturated, disk full, slow storage, or a rotation/compression stall), the event cannot be made durable, so the ordinary "emit an ingestion-overflow event into the log" response is unavailable — that write would fail too. The survivable mechanism is:

- A small, **pre-allocated emergency journal** on a reserved reservation (ADR-013), separate from the rotating log and sized so a write there cannot itself hit disk-full, records the **lost sequence range(s)** (session generation + first/last dropped sequence) and a monotonic timestamp.
- The receive loop keeps assigning sequence numbers to dropped events (it never stops counting), so the loss appears as a **sequence discontinuity** in the log. On recovery, `guardian-can` reconciles the emergency journal against the log and **synthesises ingestion-overflow / ingestion-gap events** (ADR-004) covering exactly the discontinuous ranges, which core then processes in order.
- Device-health is marked degraded immediately. The loop continues receiving; it never stalls SocketCAN waiting for storage.

Loss of durability is therefore always bounded, counted (by the emergency journal and/or the sequence discontinuity), ordered, and alertable — never silent — even when the primary log is the component that failed.

Rotation and compression run without dropping the tail: the active segment remains appendable while a prior segment compresses, and termination during rotation must leave a recoverable log (a partially written segment is detectable and skipped on restart, not replayed as valid events).

### Acceptance criteria (Phase 4)

- Sustained input above nominal Jr 2 frame rate with `guardian-core` stopped: no receive-loop stall; every event either delivered on reconnect via replay or accounted for by a synthesised gap/overflow event.
- **Log-path failure injection** — disk-full and artificially slowed/stalled storage during ingestion: the emergency journal records the lost sequence ranges; on recovery, overflow/gap events are synthesised for exactly the sequence discontinuities; no silent loss; device-health shows degraded.
- **Emergency-journal survivability** — disk-full occurring *before* the loss is recorded: the reserved journal write still succeeds (it is pre-allocated), or, if even that is impossible, the sequence discontinuity alone is sufficient for core to synthesise the gap on recovery. No loss is silent under either sub-case.
- Process kill (SIGKILL) of `guardian-can` during segment rotation: on restart the log opens cleanly, the partial segment is skipped, no corrupt event is replayed, and any discontinuity across the kill is reported as a gap.
- IPC send-queue saturation with the log healthy: dropped IPC events are all recovered by core via replay-after-checkpoint with no gap marker (they were durable); final processed set equals the logged set (subject to the delivery contract in ADR-011).

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
