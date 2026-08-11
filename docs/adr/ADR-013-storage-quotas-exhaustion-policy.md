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

### Reserved capacity and eviction order

- A **reserve** is held that only *current* operational safety state (open findings, live alert/incident state, last-seen marker, config) and queued alert uplinks may use; telemetry, observations, and routine log data never encroach on it.
- Under pressure, eviction follows a fixed safety order: (1) oldest downsampled telemetry, (2) unpinned ingestion-log tail, (3) closed-incident pinned evidence, (4) low-priority outbound backlog — never the reserved set above.

### Compaction keeps the protected set bounded

"Never evicted" is only honest if the protected set is bounded. **Compaction** (distinct from eviction) discards redundant history while keeping current safety truth: closed incidents collapse to durable summaries after a window (their bulk evidence then evictable); superseded alert transitions collapse to current state plus a bounded history (first occurrence kept); acknowledged items become compaction-eligible; undelivered uplinks are bounded per priority (newest-per-entity). The current-safety working set thus stays within the reserve while history degrades gracefully.

### Exhaustion behaviour

- Approaching a quota raises a device-health observation, then an alert — storage pressure is a monitored condition.
- Evidence eviction emits an eviction/gap event (ADR-004/005) and degrades data-confidence (ADR-012).
- At the reserve, the device declares **degraded-persistence**: keeps ingesting and detecting, compacts aggressively, sheds lowest-value data first; never stalls ingestion, never drops a finding/alert to free space for telemetry.
- **Terminal case** (reserve full of only protected, non-compactable records): it raises a pre-allocated **persistence-saturated** alert, stops new low-priority persistence, and only if still stuck sheds the oldest/lowest-priority *within* the protected class with an explicit loss event. The promise is bounded honestly: guaranteed for the bounded current-safety set; beyond it, loss is explicit and prioritised, never a silent stall. Reserve size is provisioned in Phase 4 against worst-case concurrent open incidents.

## Consequences

- A long outage or incident storm degrades predictably: telemetry resolution shrinks first, then history compacts; the current-safety set and alert uplinks survive within the reserve, with any further loss explicit.
- One arbitration policy instead of consumers racing for free space.
- Quotas + reserve size are Phase 4 tuning (configuration); they give the concrete bounds ADR-005/006/008 refer to without specifying.

## Alternatives considered

- **Rely on the filesystem / let writes fail at disk-full** — rejected: failure lands wherever the next write happens, often on safety-relevant state, and is effectively silent.
- **Single shared pool, first-come-first-served** — rejected: telemetry bursts or a large pin can starve operational state; contradicts the fail-explicitly principle.
- **Unbounded any consumer** — rejected (consistent with ADR-005): bounded behaviour is a safety property.
