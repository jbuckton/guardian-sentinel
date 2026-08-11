# ADR-007: Single-Writer Ownership per SQLite Database

**Status:** Accepted
**Date:** 2026-08-06

## Context

Multiple components inside `guardian-core` need to record state: the rules engine writes findings and alerts, the telemetry pipeline writes batches, and the MQTT delivery component must update outbound delivery state (acknowledged, retried, expired). Independent writers to the same SQLite database create lock contention that can surface as consumer lag indistinguishable from a CAN or decoding problem.

## Decision

Each SQLite database (ADR-006) has exactly **one owning writer** — a single component (thread/task) that performs all writes to that database.

- All other components, including MQTT delivery, submit state changes as messages/requests through the owning writer's bounded queue rather than writing independently.
- Reads may occur from other components under WAL, but writes are exclusively the owner's.
- The owning writer enforces the write discipline of ADR-006: batching for telemetry, immediate durability for alert transitions, findings, bus-off and configuration changes.
- The operational writer performs **atomic duplicate suppression of Tier-2 safety transitions** by their deterministic effect identity (ADR-011) — a unique-key/insert-or-ignore applied within its single write path — so a restart re-delivery cannot duplicate a finding or reopen an incident. Being the sole writer is what makes this suppression atomic without cross-writer locks.
- Writer queues are bounded; queue depth and write latency are device-health metrics.

## Consequences

- Lock contention is eliminated by construction; SQLite busy-timeouts stop being a tuning surface.
- Delivery-state updates from MQTT are serialised with other operational writes, keeping the outbound queue's state consistent with alerts and incidents.
- The owning-writer queue becomes the single place to observe persistence backpressure.
- Slight indirection cost: components cannot "just write" — accepted as the price of predictable persistence behaviour.

## Alternatives considered

- **Independent writers with busy-timeout tuning** — rejected: contention is workload-dependent and reappears under exactly the incident bursts where persistence matters most.
- **A separate storage service/process** — rejected for the MVP per ADR-003's deployment principle; may be revisited by a later ADR if testing shows a concrete need.
