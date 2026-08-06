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
