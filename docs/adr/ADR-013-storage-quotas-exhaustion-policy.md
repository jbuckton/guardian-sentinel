# ADR-013: Storage Quotas and Exhaustion Policy

**Status:** Accepted
**Date:** 2026-08-07

## Context

The device has a finite 16 GB eMMC and must run unattended and offline for extended periods. Four consumers compete for that space: the bounded ingestion log (ADR-005), pinned incident evidence (ADR-005), the two SQLite databases with their retention tiers (ADR-006), and the outbound MQTT backlog during an outage (ADR-008). ADR-005 already calls storage exhaustion "itself a safety-relevant failure," but no ADR yet defines the quotas or what happens when they are hit. Undefined exhaustion behaviour means an offline outage or an incident burst could silently starve safety-relevant state — the exact failure the product exists to prevent.

## Decision

Each storage consumer has a **hard, explicit quota**, and total quotas plus a reserve fit within a configured device storage budget strictly smaller than the physical partition. No consumer may grow past its quota by borrowing another's space.

### Quotas (all configuration, tuned in Phase 4)

- **Ingestion log** — size- and/or time-bounded; rotates and evicts oldest-first within its quota (ADR-005).
- **Pinned evidence** — a bounded budget *carved from within* the ingestion-log quota, not additional to it, so pinning can never grow the log without bound (ADR-005 eviction rules apply).
- **Telemetry DB** — bounded by retention + downsample tiers (ADR-006); oldest, most-downsampled data evicted first.
- **Operational DB** — bounded, but see reserved capacity below; it is evicted last and least.
- **Outbound MQTT backlog** — bounded queue with priority (alerts first) and throttling (ADR-008); when full, lowest-priority telemetry is dropped from the backlog before any alert/finding.

### Reserved capacity for safety-relevant state

- A **reserve** is held that only the operational DB and the outbound alert/finding queue may consume. Telemetry, observations, and routine log data may never encroach on it.
- Under global pressure the eviction order is fixed and safety-ordered: (1) oldest downsampled telemetry, (2) routine (unpinned) ingestion-log tail, (3) closed-incident pinned evidence, (4) low-priority outbound backlog — and **never** operational safety state (findings, alert/incident state, checkpoint, config) or queued alert uplinks, which live in the reserve.

### Exhaustion behaviour

- Approaching any quota raises a **device-health observation** and, past a configured threshold, an alert — storage pressure is itself a monitored condition, not a surprise.
- Eviction of any evidence (log tail or pinned range) emits the corresponding ingestion-gap/eviction event (ADR-004/005) so loss is recorded, ordered, and alertable — never silent.
- If the reserve itself is ever threatened, the device enters a declared **degraded-persistence** state (surfaced in device-health and via ADR-012's device/health reporting): it keeps ingesting and detecting, keeps safety state durable, and sheds the lowest-value data first; it never stalls ingestion (ADR-003) and never drops a finding or alert transition to make room for telemetry.
- Writes of safety-relevant operational state must not fail for lack of space while any lower-priority data remains evictable; the writer reclaims from the eviction order first.

## Consequences

- A long offline outage or an incident storm degrades predictably: telemetry resolution and replay depth shrink first; alerts, findings, and their evidence survive.
- The competing consumers have a single arbitration policy instead of racing for free space.
- Quotas + reserve size are named Phase 4 tuning tasks against eMMC endurance and required replay/evidence depth; they are configuration, so field tuning needs no code change.
- Provides the concrete bounds ADR-005 (log), ADR-006 (DB retention), and ADR-008 (backlog) each referred to without specifying.

## Alternatives considered

- **Rely on the filesystem / let writes fail at disk-full** — rejected: failure lands wherever the next write happens, often on safety-relevant state, and is effectively silent.
- **Single shared pool, first-come-first-served** — rejected: telemetry bursts or a large pin can starve operational state; contradicts the fail-explicitly principle.
- **Unbounded any consumer** — rejected (consistent with ADR-005): bounded behaviour is a safety property.
