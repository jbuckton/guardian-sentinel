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

Separate **operational** state from **high-volume telemetry** — as separate SQLite database files (preferred) or, at minimum, independently managed tables with independent writers:

- **Operational DB:** configuration, versions, alerts, incidents, findings, outbound delivery state, core's replay checkpoint (ADR-005), device-health summaries.
- **Telemetry DB:** normalised telemetry and observations, batched and downsampled under bounded retention.

### Write discipline

- Batched transactions for routine telemetry; immediate durable writes for findings, alert transitions, bus-off events and configuration changes.
- Bounded retention with downsampling tiers; retention limits are configuration.
- Raw CAN frames are **never** synchronously inserted into SQLite. Raw evidence lives in the bounded ingestion log (ADR-005), with high-resolution evidence pinned around incidents.
- WAL mode; exact PRAGMA/durability settings validated in Phase 4 power-loss testing.

## Consequences

- eMMC wear is controlled by batching, downsampling and keeping raw frames out of the database.
- Operational writes (an alert transition) are never queued behind a telemetry batch.
- Two databases require the writer-ownership rule in ADR-007 to avoid lock contention masquerading as ingestion lag.
- A future move to another store (if ever needed) is a new ADR; nothing in the MVP schema should assume one.

## Alternatives considered

- **One database for everything** — rejected: telemetry write bursts contend with operational durability requirements.
- **Time-series database on-device** — rejected: unnecessary operational weight on a CM4 for MVP volumes.
- **Raw frames in SQLite** — rejected: write amplification and eMMC endurance risk.
