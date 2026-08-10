# ADR-006: SQLite for Edge Persistence, Separated by Concern

**Status:** Accepted
**Date:** 2026-08-06

## Context

The edge device needs durable local storage that survives power loss, runs on a 16 GB eMMC with finite write endurance, and requires no external service. Telemetry volume is high and steady; operational state (configuration, alerts, checkpoints) is low-volume but must be updated with strong durability.

## Decision

Use **SQLite** for the first edge implementation. SQLite is authoritative locally for:

- Configuration
- Rule and decoder versions
- Normalised telemetry
- Observations
- Findings
- Alerts
- Incidents
- Outbound delivery state
- Device-health history

### Separation of concerns

Operational state and high-volume telemetry live in **two separate SQLite database files**. This is the accepted topology, not a preference: a single file with independently managed tables is **rejected** here because it reintroduces exactly the cross-writer lock contention that ADR-007 (single writer per database) exists to eliminate, and the implementation plan assumes two files. Each file has exactly one owning writer (ADR-007).

- **Operational DB** — owner: the **operational writer**. Holds configuration, rule/decoder versions, findings, alerts, incidents, outbound delivery state, core's replay checkpoint (ADR-005), evidence-pin references (the pin request IDs and pinned ranges tracked against incidents), and device-health history. All immediate-durability writes land here.
- **Telemetry DB** — owner: the **telemetry writer**. Holds normalised telemetry and observations, batched and downsampled under bounded retention.

### Ownership of ambiguous records

- **Observations** live in the telemetry DB (they are high-volume, derived from telemetry, and downsamplable) and are written by the telemetry writer. A **finding** that promotes an observation copies or references the evidence into the operational DB, where its durability and retention are governed by operational, not telemetry, rules.
- **Device-health** history is operational (it drives alerts and must survive telemetry pruning) and is written by the operational writer.
- **Evidence references** — pointers into the ingestion log's pinned ranges (ADR-005) — are operational and written by the operational writer, so an incident and the evidence it pins share one durable owner and cannot diverge.
- Neither writer writes to the other's database; cross-database consistency is achieved by each writer owning its side and referencing the other by durable identity, never by a shared transaction across files.

### Write discipline

Durability is applied **per data class**, matching the tiers in ADR-005, so the high-volume path never pays frame-rate `fsync` (the dominant eMMC-wear risk on the CM4):

- **Operational safety state (Tier 2) is durable on change** — findings, alert transitions, incident state, bus-off, and configuration changes are written with immediate durability. This is low-volume and rare, so its `fsync` cost is negligible, and forgetting an active alarm across a reboot is unacceptable.
- **Telemetry is best-effort and batched (Tier 0)** — batched transactions, downsampling tiers, bounded retention (limits are configuration). Loss is permitted but surfaces as an explicit gap (ADR-005); it is never `fsync`ed per row.
- Raw CAN frames are **never** synchronously inserted into SQLite. Raw evidence lives in the bounded ingestion buffer (ADR-005), best-effort in the MVP, with incident evidence pinned via pre-roll on trigger.
- WAL mode. The MVP deliberately **avoids per-event `fsync`**: telemetry on `synchronous=NORMAL` (fsync at checkpoint, not per commit); operational on `FULL` (cheap at its volume). Exact PRAGMA/group-commit/durability tuning — and any move toward the ADR-005 durable tier — is deferred to Phase 4 power-loss and endurance testing, not fixed here.

## Consequences

- eMMC wear is controlled by batching, downsampling and keeping raw frames out of the database.
- Operational writes (an alert transition) are never queued behind a telemetry batch.
- Two databases require the writer-ownership rule in ADR-007 to avoid lock contention masquerading as ingestion lag.
- Retention bounds and exhaustion policy for both databases are specified in ADR-013 (storage quotas), which reserves capacity for safety-relevant operational state ahead of telemetry.
- A future move to another store (if ever needed) is a new ADR; nothing in the MVP schema should assume one.

## Alternatives considered

- **One database for everything** — rejected: telemetry write bursts contend with operational durability requirements.
- **Time-series database on-device** — rejected: unnecessary operational weight on a CM4 for MVP volumes.
- **Raw frames in SQLite** — rejected: write amplification and eMMC endurance risk.
